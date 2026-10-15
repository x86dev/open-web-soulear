/// Camera driver for AIR-Look WiFi ear cameras (Enjoy-866, MoLink TX816).
///
/// Dart port of app/server/src/camera/airlook.ts: discovery -> TCP control
/// channel + start command for the video stream, then a periodic heartbeat
/// (keeps the stream alive) and status polling (voltage/battery). The video
/// stream arrives as UDP video packets that are assembled into JPEGs. No
/// orientation sensor, no LED. Pure Dart (dart:io), no Flutter.
library;

import 'dart:async';
import 'dart:convert';
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
  CameraCapabilities get capabilities => const CameraCapabilities(led: false, battery: true, sensors: false);

  static const _requestTimeout = Duration(seconds: 3);
  static const _probeTimeout = Duration(milliseconds: 1500);
  static const _videoHeartbeat = Duration(milliseconds: 600);
  static const _statusPoll = Duration(milliseconds: 1800);

  RawDatagramSocket? _cmd;
  RawDatagramSocket? _videoSock;
  Socket? _tcp;
  final _assembler = air.VideoFrameAssembler();
  Timer? _heartbeatTimer;
  Timer? _statusTimer;
  late InternetAddress _addr;
  air.AirDeviceInfo? _deviceInfo;

  @override
  Future<void> connect() async {
    if (status.connected) return;
    setStatus(status.copyWith(clearError: true, capabilities: capabilities));
    try {
      _addr = InternetAddress(config.ip);
      _cmd = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _videoSock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _videoSock!.listen((e) {
        if (e == RawSocketEvent.read) _onVideoData();
      });

      await _discover();
      log('Camera: ${_deviceInfo?.model ?? "unknown"}');

      setStatus(status.copyWith(connected: true));
      _connectTcp();
      _sendVideoHeartbeat();

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
    _cmd?.close();
    _videoSock?.close();
    _cmd = null;
    _videoSock = null;
    _assembler.reset();
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await closeControllers();
  }

  @override
  Future<void> setLed(int level) =>
      Future.error(const CameraException('AIR-Look cameras have no controllable LED'));

  // --- internal -------------------------------------------------------------

  /// Discovery: query the device info via UDP and parse the JSON.
  Future<void> _discover() async {
    final res = await _sendRequest(config.cmdPort, air.encodeDiscoveryRequest());
    final parsed = air.parseDiscoveryResponse(res);
    if (parsed == null) {
      throw CameraException('Camera did not respond (${config.ip}:${config.cmdPort})');
    }
    try {
      _deviceInfo = air.AirDeviceInfo.fromJson(jsonDecode(parsed.$2) as Map<String, dynamic>);
    } catch (_) {
      throw const CameraException('Discovery: invalid JSON response');
    }
    setStatus(status.copyWith(details: {
      ...status.details,
      'Manufacturer': _deviceInfo?.manufacturer.isNotEmpty == true ? _deviceInfo!.manufacturer : (config.ip),
      'Model': _deviceInfo?.model.isNotEmpty == true ? _deviceInfo!.model : 'unknown',
      'Firmware': _deviceInfo?.firmware ?? '',
      'MAC': _deviceInfo?.mac ?? '',
    }));
  }

  Future<void> _pollStatus() async {
    try {
      final res = await _sendStatusRequest(config.cmdPort, air.encodeStatusRequest());
      final s = air.parseStatusResponse(res);
      if (s == null) return;
      setStatus(status.copyWith(
        battery: s.battery.clamp(0, 100),
        details: {...status.details, 'Voltage': '${s.voltage} mV'},
        clearError: true,
      ));
    } catch (e) {
      log('Status poll failed: $e');
    }
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
      emitFrame(Frame(frame.jpeg, 0, 0, (0, 0, 0), (0, 0)));
      setStatus(status); // updates the frame rate centrally, among other things
    }
  }

  /// One-shot request on the command socket; response from the device by IP.
  Future<Uint8List> _sendRequest(int port, Uint8List data, [Duration? timeout]) {
    final sock = _cmd;
    if (sock == null) return Future.error(const CameraException('not connected'));
    return _udpOnce(sock, port, data, timeout ?? _requestTimeout);
  }

  Future<Uint8List> _sendStatusRequest(int port, Uint8List data, [Duration? timeout]) async {
    // Own socket, like in the Node driver, so the status response does not
    // collide with other responses.
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      return await _udpOnce(sock, port, data, timeout ?? _requestTimeout);
    } finally {
      sock.close();
    }
  }

  Future<Uint8List> _udpOnce(
    RawDatagramSocket sock,
    int port,
    Uint8List data,
    Duration timeout,
  ) {
    final completer = Completer<Uint8List>();
    StreamSubscription<RawSocketEvent>? sub;

    void finish(Uint8List? value, Object? error) {
      sub?.cancel();
      if (!completer.isCompleted) {
        if (error != null) {
          completer.completeError(error);
        } else {
          completer.complete(value);
        }
      }
    }

    sub = sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = sock.receive()) != null) {
        if (d!.address != _addr) continue;
        finish(d.data, null);
        return;
      }
    });

    final timer = Timer(timeout, () => finish(null, const CameraException('timeout')));
    completer.future.whenComplete(timer.cancel);

    sock.send(data, _addr, port);
    return completer.future;
  }

  /// Detection probe: a short discovery request without starting the client.
  Future<bool> probe() async {
    try {
      _addr = InternetAddress(config.ip);
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        final res = await _udpOnce(sock, config.cmdPort, air.encodeDiscoveryRequest(), _probeTimeout);
        return air.parseDiscoveryResponse(res) != null;
      } finally {
        sock.close();
      }
    } catch (_) {
      return false;
    }
  }
}

void _noLog(String _) {}
