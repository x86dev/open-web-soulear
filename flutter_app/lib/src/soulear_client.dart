/// Camera driver for Soulear/Suear cameras (UDP). Pure Dart (dart:io), runs in
/// the app and as a command-line program (tool/probe.dart).
///
/// Flow as in app/server/src/camera/soulear.ts: GetDeviceInfo -> open video
/// ports -> OpenVideo (first with our own receive port as payload, on failure
/// without) -> assemble chunks into JPEGs. If no video data arrives, OpenVideo
/// is repeated.
library;

import 'dart:async';
import 'dart:io';

import 'camera.dart';
import 'protocol.dart';

class SoulearConfig {
  const SoulearConfig({
    this.ip = '192.168.1.1',
    this.cmdPort = 10005,
    this.videoPort = 10006,
    this.streamPorts = const [22785, 22789],
  });
  final String ip;
  final int cmdPort;
  final int videoPort;
  final List<int> streamPorts;
}

class SoulearClient extends BaseCameraDriver {
  SoulearClient({this.config = const SoulearConfig(), this.log = _noLog});

  final SoulearConfig config;
  final void Function(String) log;

  @override
  String get name => 'soulear';

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(led: true, battery: true, sensors: true);

  static const _stall = Duration(seconds: 6);
  static const _infoInterval = Duration(seconds: 10);

  RawDatagramSocket? _cmd;
  final _streamSocks = <RawDatagramSocket>[];
  final _assembler = FrameAssembler();
  final _smoother = SensorSmoother();
  late InternetAddress _addr;
  int _msgId = 0;
  Future<void> _queue = Future.value();
  _PendingRequest? _pending;
  bool _usePortPayload = true;
  bool _everReceived = false;
  bool _stallError = false;
  bool _restartPending = false;
  DateTime _lastData = DateTime.now();
  Timer? _watchdog;
  Timer? _infoTimer;
  int _infoFailures = 0;

  @override
  Future<void> connect() async {
    if (status.connected) return;
    setStatus(status.copyWith(clearError: true, capabilities: capabilities));
    _everReceived = false;
    _usePortPayload = true;
    try {
      _addr = InternetAddress(config.ip);
      _cmd = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _cmd!.listen((e) {
        if (e == RawSocketEvent.read) _onCmdData();
      });

      final String info;
      try {
        info = await _updateInfo();
      } catch (_) {
        throw CameraException(
            'Kamera antwortet nicht (${config.ip}:${config.cmdPort}). Ist das Gerät im WLAN der Kamera?');
      }
      log('Kamera: $info');

      await _openStreamSockets();
      setStatus(status.copyWith(connected: true));
      await _openVideo();

      // Like the original app: light on after connecting.
      try {
        await setLed(100);
      } catch (e) {
        log('LED einschalten fehlgeschlagen: $e');
      }

      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkStall());
      _infoTimer = Timer.periodic(_infoInterval, (_) => _pollInfo());
    } catch (e) {
      await _teardown();
      setStatus(status.copyWith(error: e is CameraException ? e.message : '$e'));
      rethrow;
    }
  }

  @override
  Future<void> disconnect() => _teardown();

  @override
  Future<void> dispose() async {
    await _teardown();
    await closeControllers();
  }

  @override
  Future<void> setLed(int level) async {
    final res = await _request(config.cmdPort, MsgType.led, ledSetPayload(level));
    if (res.errCode != 0) throw CameraException('LED: Fehlercode ${res.errCode}');
    setStatus(status.copyWith(led: level.clamp(0, 100)));
    // Align the display with the camera's actual state.
    try {
      await _readLed();
    } catch (_) {}
  }

  // --- internal -------------------------------------------------------------

  Future<void> _teardown() async {
    _watchdog?.cancel();
    _infoTimer?.cancel();
    _watchdog = _infoTimer = null;
    _cmd?.close();
    _cmd = null;
    for (final s in _streamSocks) {
      s.close();
    }
    _streamSocks.clear();
    _assembler.reset();
    _smoother.reset();
    final p = _pending;
    _pending = null;
    if (p != null) {
      p.timer.cancel();
      if (!p.completer.isCompleted) p.completer.completeError(const CameraException('getrennt'));
    }
    resetFps();
    setStatus(status.copyWith(connected: false));
  }

  Future<String> _updateInfo() async {
    final res = await _request(config.cmdPort, MsgType.getDeviceInfo);
    final info = parseDeviceInfo(res.data);
    if (info == null) throw CameraException('GetDeviceInfo: unerwartete Antwort (${res.data.length} Byte)');
    setStatus(status.copyWith(
      battery: info.battery,
      charging: info.charging,
      details: {
        ...status.details,
        'Hersteller': info.vendor,
        'Modell': info.product,
        'Firmware': info.firmware,
        'SSID': info.ssid,
        'Laden': info.charging ? 'ja' : 'nein',
      },
    ));
    return '${info.vendor} ${info.product} ${info.firmware}, Akku ${info.battery} %';
  }

  Future<void> _readLed() async {
    final res = await _request(config.cmdPort, MsgType.led, ledQueryPayload());
    final level = parseLedStatus(res.data);
    if (level != null) setStatus(status.copyWith(led: level));
  }

  Future<void> _pollInfo() async {
    const lost = 'Kamera antwortet nicht mehr auf Statusabfragen';
    try {
      await _updateInfo();
      try {
        await _readLed();
      } catch (_) {}
      _infoFailures = 0;
      if (status.error == lost) setStatus(status.copyWith(clearError: true));
    } catch (_) {
      if (++_infoFailures >= 3) setStatus(status.copyWith(error: lost));
    }
  }

  Future<void> _openStreamSockets() async {
    // Retry the preferred port first over the time window, so a port that is
    // still busy does not divert the video stream.
    for (var i = 0; i < config.streamPorts.length; i++) {
      final port = config.streamPorts[i];
      final sock = await _bindStreamPort(port, isPreferred: i == 0);
      if (sock != null) return; // the first successfully bound port is advertised
    }
    throw CameraException('Keiner der Bild-Ports ${config.streamPorts.join('/')} ist frei');
  }

  Future<RawDatagramSocket?> _bindStreamPort(int port, {required bool isPreferred}) async {
    final deadline = DateTime.now().add(isPreferred ? const Duration(seconds: 3) : Duration.zero);
    for (;;) {
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
        s.listen((e) {
          if (e == RawSocketEvent.read) _onStreamData(s, port);
        });
        _streamSocks.add(s);
        return s;
      } catch (e) {
        if (DateTime.now().isAfter(deadline)) {
          log('Bild-Port $port nicht nutzbar: $e');
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _openVideo() async {
    try {
      await _sendOpenVideo();
    } catch (e) {
      // Older firmware may not know the port payload -> try without it.
      // If the port mode already delivered frames, it is just a drop-out.
      if (!_usePortPayload || _everReceived) rethrow;
      log('OpenVideo mit Port fehlgeschlagen ($e) – versuche ohne Nutzlast');
      _usePortPayload = false;
      await _sendOpenVideo();
    }
  }

  Future<void> _sendOpenVideo() async {
    final payload = <int>[];
    if (_usePortPayload) {
      final p = config.streamPorts.first;
      payload.addAll([p & 0xff, (p >> 8) & 0xff]);
    }
    final res = await _request(config.videoPort, MsgType.openVideo, payload);
    if (res.errCode != 0) throw CameraException('OpenVideo: Fehlercode ${res.errCode}');
    _lastData = DateTime.now();
    log('OpenVideo gesendet (${_usePortPayload ? 'mit Port' : 'ohne Nutzlast'})');
  }

  void _checkStall() {
    refreshFps();

    if (!status.connected || _restartPending || DateTime.now().difference(_lastData) < _stall) return;
    if (!_everReceived && _usePortPayload) _usePortPayload = false;
    _stallError = true;
    final msg = _everReceived ? 'Bildstrom unterbrochen – starte neu' : 'Keine Bilddaten – versuche anderen Startmodus';
    setStatus(status.copyWith(error: msg));
    log(msg);
    _lastData = DateTime.now();
    _restartPending = true;
    _openVideo().catchError((Object e) => log('OpenVideo fehlgeschlagen: $e')).whenComplete(() => _restartPending = false);
  }

  void _onStreamData(RawDatagramSocket sock, int port) {
    Datagram? d;
    while ((d = sock.receive()) != null) {
      if (d!.address != _addr) continue;
      _lastData = DateTime.now();
      if (!_everReceived) {
        _everReceived = true;
        log('Erste Bilddaten auf Port $port');
        setStatus(status.copyWith(details: {
          ...status.details,
          'Empfangsport': '$port',
          'Startmodus': _usePortPayload ? 'port' : 'plain',
        }));
      }
      if (_stallError) {
        _stallError = false;
        setStatus(status.copyWith(clearError: true));
      }
      for (final chunk in parseChunks(d.data)) {
        final frame = _assembler.push(chunk);
        if (frame == null) continue;
        final res = '${frame.width}×${frame.height}';
        if (status.details['Auflösung'] != res) {
          setStatus(status.copyWith(details: {...status.details, 'Auflösung': res}));
        }
        emitFrame(frame);
        emitSensor(_smoother.push(frame.accel, frame.flags));
      }
    }
  }

  void _onCmdData() {
    final sock = _cmd;
    if (sock == null) return;
    Datagram? d;
    while ((d = sock.receive()) != null) {
      final p = _pending;
      if (p == null || d!.address != _addr || d.port != p.port) continue;
      final msg = decodeMessage(d.data);
      if (msg == null || msg.type != p.type) continue;
      _pending = null;
      p.timer.cancel();
      p.completer.complete(msg);
    }
  }

  /// Request/response, serialized - the camera answers one request after the
  /// other; matched via source port and message type.
  Future<Message> _request(int port, int type, [List<int> data = const [], int attempts = 3]) {
    Future<Message> run() async {
      Object lastErr = const CameraException('keine Antwort');
      for (var i = 0; i < attempts; i++) {
        try {
          return await _requestOnce(port, type, data);
        } catch (e) {
          lastErr = e;
        }
      }
      throw lastErr;
    }

    final result = _queue.then((_) => run(), onError: (_) => run());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Message> _requestOnce(int port, int type, List<int> data) {
    final sock = _cmd;
    if (sock == null) return Future.error(const CameraException('nicht verbunden'));
    final completer = Completer<Message>();
    final timer = Timer(const Duration(milliseconds: 1500), () {
      if (_pending?.completer == completer) _pending = null;
      if (!completer.isCompleted) {
        completer.completeError(CameraException('Zeitüberschreitung (Typ $type, Port $port)'));
      }
    });
    _pending = _PendingRequest(port, type, completer, timer);
    sock.send(encodeMessage(_msgId++, type, data), _addr, port);
    return completer.future;
  }
}

class _PendingRequest {
  _PendingRequest(this.port, this.type, this.completer, this.timer);
  final int port;
  final int type;
  final Completer<Message> completer;
  final Timer timer;
}

void _noLog(String _) {}
