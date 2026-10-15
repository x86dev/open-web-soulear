/// Camera driver for AIR-Look WiFi ear cameras (Enjoy-866, MoLink TX816).
///
/// Dart port of app/server/src/camera/airlook.ts: discovery -> TCP control
/// channel + start command for the video stream, then a periodic heartbeat
/// (keeps the stream alive) and status polling (voltage/battery). The video
/// stream arrives as UDP video packets that are assembled into JPEGs. The LED
/// can be switched on/off; there is no orientation sensor. Pure Dart (dart:io),
/// no Flutter.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'airlook_protocol.dart' as air;
import 'camera.dart';
import 'protocol.dart';

class AirlookConfig {
  const AirlookConfig({
    this.ip = '192.168.0.10',
    this.cmdPort = air.discoveryPort,
    this.videoPort = air.videoPort,
  });
  final String ip;
  final int cmdPort;
  final int videoPort;
}

class AirlookClient extends BaseCameraDriver {
  AirlookClient({this.config = const AirlookConfig(), this.log = _noLog});

  final AirlookConfig config;
  final void Function(String) log;

  @override
  String get name => 'airlook';

  @override
  CameraCapabilities get capabilities => const CameraCapabilities(led: true, battery: true, sensors: true);

  static const _requestTimeout = Duration(seconds: 3);
  static const _probeTimeout = Duration(milliseconds: 1500);
  static const _videoHeartbeat = Duration(milliseconds: 600);
  static const _statusPoll = Duration(milliseconds: 1800);

  RawDatagramSocket? _cmd;
  RawDatagramSocket? _videoSock;
  Socket? _tcp;
  final _assembler = air.VideoFrameAssembler();

  /// Smooths the per-frame accelerometer readings, same filtering as the
  /// soulear driver (libWifiCamera's sensor_get_xyz).
  final _smoother = SensorSmoother();
  Timer? _heartbeatTimer;
  Timer? _statusTimer;
  late InternetAddress _addr;
  air.AirDeviceInfo? _deviceInfo;

  /// Monotonic index for Format-B requests (LED).
  int _seq = 0;
  bool _ledLogged = false;

  /// Serializes command-socket requests. A RawDatagramSocket is a
  /// single-subscription stream, so the socket keeps one persistent listener
  /// (installed in [connect]) and requests are handled strictly one after
  /// another. Concurrent requests - e.g. the LED read inside a status poll -
  /// would otherwise fight over the socket and silently drop the toggle.
  Future<void> _queue = Future.value();

  /// The request currently waiting for its reply. Completed by [_onCmdData].
  _PendingRequest? _pending;

  @override
  Future<void> connect() async {
    if (status.connected) return;
    setStatus(status.copyWith(clearError: true, capabilities: capabilities));
    try {
      _addr = InternetAddress(config.ip);
      _cmd = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // The command socket gets exactly one listener for its whole lifetime;
      // replies are routed to the request currently in flight.
      _cmd!.listen((e) {
        if (e == RawSocketEvent.read) _onCmdData();
      });
      _videoSock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _videoSock!.listen((e) {
        if (e == RawSocketEvent.read) _onVideoData();
      });

      await _discover();
      log('Camera: ${_deviceInfo?.model ?? "unknown"}');

      setStatus(status.copyWith(connected: true));
      _connectTcp();
      _sendVideoHeartbeat();

      // Read the LED state once immediately, so the UI matches the device
      // (the LED is on at power-on) instead of waiting for the first poll.
      try {
        await _readLed();
      } catch (_) {}

      _heartbeatTimer = Timer.periodic(_videoHeartbeat, (_) => _sendVideoHeartbeat());
      _statusTimer = Timer.periodic(_statusPoll, (_) => _pollStatus());
    } catch (e) {
      await disconnect();
      setStatus(status.copyWith(error: e is CameraException ? e.message : '$e'));
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    resetFps();
    setStatus(status.copyWith(connected: false));
    _heartbeatTimer?.cancel();
    _statusTimer?.cancel();
    _heartbeatTimer = _statusTimer = null;
    await _tcp?.close();
    _tcp = null;
    _pending?.completeError(const CameraException('disconnected'));
    _pending = null;
    _cmd?.close();
    _videoSock?.close();
    _cmd = null;
    _videoSock = null;
    _assembler.reset();
    _smoother.reset();
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await closeControllers();
  }

  @override
  Future<void> setLed(int level) async {
    // The AIR-Look LED is binary (off = 0, on = any non-zero value); send 1/0.
    final value = level > 0 ? 1 : 0;
    final res = await _sendFormatB(air.encodeSetLed(value, ++_seq));
    if (res == null) throw const CameraException('SetLed: no response from the camera');
    setStatus(status.copyWith(led: value));
    // Align the display with the actual state, like the soulear driver does.
    try {
      await _readLed();
    } catch (_) {}
  }

  /// Reads the LED value from the camera (GetPwm 0x1015); keeps the old value on failure.
  Future<void> _readLed() async {
    final res = await _sendFormatB(air.encodeGetLed(++_seq));
    final raw = res == null ? null : air.parseLedStatus(res);
    if (!_ledLogged) {
      _ledLogged = true;
      log('LED query -> ${res == null ? "(no response)" : res.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
          ' => ${raw ?? "unreadable"}');
    }
    // The LED is binary: 0 = off, any non-zero value = on.
    if (raw != null) setStatus(status.copyWith(led: raw > 0 ? 1 : 0));
  }

  /// Sends a Format-B packet on the command socket and returns the raw reply (or null).
  Future<Uint8List?> _sendFormatB(Uint8List packet) async {
    try {
      return await _exchange(config.cmdPort, packet, _requestTimeout);
    } catch (_) {
      return null;
    }
  }

  // --- internal -------------------------------------------------------------

  /// Discovery: query the board info via UDP (getBoardInfo 0x1060) and parse it.
  Future<void> _discover() async {
    final res = await _sendRequest(config.cmdPort, air.encodeGetBoardInfo(++_seq));
    final info = air.parseBoardInfo(res);
    if (info == null) {
      throw CameraException('Camera did not respond (${config.ip}:${config.cmdPort})');
    }
    _deviceInfo = info;
    log('Board info: ${info.model.isNotEmpty ? info.model : "unknown"}');

    // Build a readable detail set; only non-empty fields so the UI shows no blanks.
    final entries = <String, String>{
      'Manufacturer': info.manufacturer.isNotEmpty ? info.manufacturer : (info.brand.isNotEmpty ? info.brand : config.ip),
      'Model': info.model.isNotEmpty ? info.model : 'unknown',
      'Hardware': info.hardware,
      'Firmware': info.firmware,
      'FW date': info.fwDate,
      'SoC': info.soc,
      'MAC': info.mac,
      'Stream': info.streamType,
    }..removeWhere((_, v) => v.isEmpty);

    setStatus(status.copyWith(details: {...status.details, ...entries}));
  }

  Future<void> _pollStatus() async {
    try {
      // getBattery (0x1017) carries voltage, charge state and percentage.
      final res = await _sendFormatB(air.encodeGetBattery(++_seq));
      final b = res == null ? null : air.parseBatteryResponse(res);
      if (b != null) {
        setStatus(status.copyWith(
          battery: b.percent ?? status.battery,
          charging: b.charging,
          details: {
            ...status.details,
            if (b.voltage != null) 'Voltage': '${b.voltage} mV',
            'Charging': b.charging ? 'yes' : 'no',
          },
          clearError: true,
        ));
      }
    } catch (e) {
      log('Status poll failed: $e');
    }

    // Read the LED state alongside the battery (best effort).
    try {
      await _readLed();
    } catch (_) {}
  }

  void _sendVideoHeartbeat() {
    _videoSock?.send(air.encodeStartStreamingCommand(), _addr, config.videoPort);
  }

  void _connectTcp() {
    var attempts = 0;
    void tryConnect() {
      if (!status.connected || attempts >= 5) return;
      Socket.connect(config.ip, air.controlPort).then((sock) {
        _tcp = sock;
        log('TCP connected to port ${air.controlPort}');
      }).catchError((Object _) {
        attempts += 1;
        if (status.connected) Timer(const Duration(seconds: 1), tryConnect);
      });
    }

    tryConnect();
  }

  void _onVideoData() {
    final sock = _videoSock;
    if (sock == null) return;
    Datagram? d;
    while ((d = sock.receive()) != null) {
      if (d!.address != _addr) continue;
      final part = air.parseVideoPacket(d.data);
      if (part == null) continue;
      final frame = _assembler.push(part);
      if (frame == null) continue;
      final res = '${frame.jpeg.length} Byte';
      if (status.details['Resolution'] != res) {
        setStatus(status.copyWith(details: {...status.details, 'Resolution': res}));
      }
      emitFrame(Frame(frame.jpeg, 0, 0, (frame.accel.x, frame.accel.y, frame.accel.z), (0, 0)));

      // The accelerometer travels in the video chunk header (one sample per
      // frame), so it is the only sensor source for this camera. The header
      // carries no flag bytes, hence the zero flags tuple.
      emitSensor(_smoother.push(
        (frame.accel.x, frame.accel.y, frame.accel.z),
        (0, 0),
      ));
      setStatus(status); // updates the frame rate centrally, among other things
    }
  }

  /// One-shot request on the command socket; response from the device by IP.
  Future<Uint8List> _sendRequest(int port, Uint8List data, [Duration? timeout]) {
    return _exchange(port, data, timeout ?? _requestTimeout);
  }

  /// Serialized request/response on the shared command socket. Requests run one
  /// after another, because only one reply can be matched at a time and the
  /// socket carries a single persistent listener.
  Future<Uint8List> _exchange(int port, Uint8List data, Duration timeout) {
    Future<Uint8List> run() {
      final sock = _cmd;
      if (sock == null) return Future.error(const CameraException('not connected'));
      return _udpOnce(sock, port, data, timeout);
    }

    final result = _queue.then((_) => run(), onError: (_) => run());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _udpOnce(
    RawDatagramSocket sock,
    int port,
    Uint8List data,
    Duration timeout,
  ) {
    final pending = _PendingRequest(
      // Opcode of the request (Format-B replies echo it at bytes [2:4]); this
      // keeps a stale reply from satisfying the request.
      wantOpcode: data.length >= 4 ? data[2] | (data[3] << 8) : null,
    );

    // Drop any datagrams already queued on the socket before sending, so an
    // earlier reply is not read as the answer to this request.
    while (sock.receive() != null) {}

    _pending = pending;
    final timer = Timer(timeout, () {
      if (_pending == pending) _pending = null;
      pending.completeError(const CameraException('timeout'));
    });

    pending.future.whenComplete(() {
      timer.cancel();
      if (_pending == pending) _pending = null;
    });

    sock.send(data, _addr, port);
    return pending.future;
  }

  /// Routes datagrams arriving on the command socket to the pending request.
  void _onCmdData() {
    final sock = _cmd;
    final pending = _pending;
    if (sock == null) return;
    Datagram? d;
    while ((d = sock.receive()) != null) {
      if (d!.address != _addr) continue;
      final want = pending?.wantOpcode;
      if (want != null && (d.data.length < 4 || (d.data[2] | (d.data[3] << 8)) != want)) {
        continue;
      }
      if (pending != null) {
        _pending = null;
        pending.complete(d.data);
      }
      return;
    }
  }

  /// Detection probe: a short discovery request without starting the client.
  Future<bool> probe() async {
    RawDatagramSocket? sock;
    try {
      _addr = InternetAddress(config.ip);
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final s = sock;
      final completer = Completer<Uint8List?>();
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          if (d!.address != _addr || completer.isCompleted) continue;
          completer.complete(d.data);
        }
      });
      s.send(air.encodeDiscoveryRequest(), _addr, config.cmdPort);
      final res = await completer.future.timeout(_probeTimeout, onTimeout: () => null);
      return res != null && air.parseDiscoveryResponse(res) != null;
    } catch (_) {
      return false;
    } finally {
      sock?.close();
    }
  }
}

/// A command-socket request waiting for its reply.
class _PendingRequest {
  _PendingRequest({required this.wantOpcode});

  final int? wantOpcode;
  final _completer = Completer<Uint8List>();

  Future<Uint8List> get future => _completer.future;

  void complete(Uint8List value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void completeError(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

void _noLog(String _) {}
