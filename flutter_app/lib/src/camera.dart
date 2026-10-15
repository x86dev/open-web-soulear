/// Shared interface of all camera drivers of the app.
///
/// Mirrors the TypeScript drivers in app/server/src/camera: `soulear`
/// (Suear/Soulear protocol), `airlook` (AIR-Look camera) and `auto` (tries
/// both in turn). Each driver delivers JPEG frames and, optionally, orientation
/// sensor values via streams, and reports its state via [status].
library;

import 'dart:async';

import 'protocol.dart';

/// What a driver can do - the UI shows/hides controls accordingly.
class CameraCapabilities {
  const CameraCapabilities({this.led = false, this.battery = false, this.sensors = false});
  final bool led;
  final bool battery;
  final bool sensors;
}

class CameraStatus {
  const CameraStatus({
    this.connected = false,
    this.fps = 0,
    this.battery,
    this.charging = false,
    this.led,
    this.error,
    this.details = const {},
    this.capabilities = const CameraCapabilities(),
  });
  final bool connected;
  final double fps;
  final int? battery;
  final bool charging;

  /// 0-100, null if unknown.
  final int? led;
  final String? error;
  final Map<String, String> details;
  final CameraCapabilities capabilities;

  CameraStatus copyWith({
    bool? connected,
    double? fps,
    int? battery,
    bool? charging,
    int? led,
    String? error,
    bool clearError = false,
    Map<String, String>? details,
    CameraCapabilities? capabilities,
  }) =>
      CameraStatus(
        connected: connected ?? this.connected,
        fps: fps ?? this.fps,
        battery: battery ?? this.battery,
        charging: charging ?? this.charging,
        led: led ?? this.led,
        error: clearError ? null : (error ?? this.error),
        details: details ?? this.details,
        capabilities: capabilities ?? this.capabilities,
      );
}

class CameraException implements Exception {
  const CameraException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A camera driver. Delivers completed JPEG frames via [frames], optionally
/// orientation sensor values via [sensors], and reports state changes via
/// [statusStream] - the latest value is also available via [status].
abstract class CameraDriver {
  /// Display name of the detected/selected driver (e.g. "soulear", "airlook").
  String get name;

  /// Last complete frame, or null.
  Frame? get lastFrame;

  /// Last (smoothed) sensor reading, or null.
  SensorReading? get lastSensor;

  /// Driver capabilities, for the UI.
  CameraCapabilities get capabilities;

  CameraStatus get status;

  /// Measured frame rate over the last seconds (frames per second).
  double get fps;

  Stream<Frame> get frames;
  Stream<SensorReading> get sensors;
  Stream<CameraStatus> get statusStream;

  /// Establishes the connection (including detection for "auto").
  Future<void> connect();

  /// Disconnects and releases sockets.
  Future<void> disconnect();

  /// Sets the LED brightness (0-100). Only if [capabilities].led.
  Future<void> setLed(int level);

  /// Releases all resources permanently.
  Future<void> dispose();
}

/// Base class with the shared status handling, frame-rate counting and
/// frame distribution - used by the concrete drivers.
abstract class BaseCameraDriver implements CameraDriver {
  final _frames = StreamController<Frame>.broadcast();
  final _sensors = StreamController<SensorReading>.broadcast();
  final _statusCtrl = StreamController<CameraStatus>.broadcast();

  @override
  Stream<Frame> get frames => _frames.stream;
  @override
  Stream<SensorReading> get sensors => _sensors.stream;
  @override
  Stream<CameraStatus> get statusStream => _statusCtrl.stream;

  CameraStatus _status = const CameraStatus();
  @override
  CameraStatus get status => _status;

  Frame? _lastFrame;
  @override
  Frame? get lastFrame => _lastFrame;

  SensorReading? _lastSensor;
  @override
  SensorReading? get lastSensor => _lastSensor;

  final _frameTimes = <DateTime>[];

  /// Window used to measure the frame rate: frames of the last 3 seconds.
  static const _fpsWindow = Duration(seconds: 3);

  @override
  CameraCapabilities get capabilities => _status.capabilities;

  @override
  double get fps => _status.fps;

  /// Frame rate over the last [_fpsWindow], in frames per second.
  double measureFps() {
    final now = DateTime.now();
    _frameTimes.removeWhere((t) => now.difference(t) > _fpsWindow);
    return (_frameTimes.length / _fpsWindow.inSeconds * 10).round() / 10;
  }

  /// Reports a new state to the listeners. The frame rate is derived centrally
  /// from the received frames - drivers do not need to set it themselves.
  void setStatus(CameraStatus s) {
    _status = s.copyWith(fps: measureFps());
    if (!_statusCtrl.isClosed) _statusCtrl.add(_status);
  }

  /// Emits a completed frame (counts the frame rate and keeps the last frame).
  void emitFrame(Frame frame) {
    _lastFrame = frame;
    _frameTimes.add(DateTime.now());
    if (!_frames.isClosed) _frames.add(frame);
  }

  /// Emits a sensor reading.
  void emitSensor(SensorReading r) {
    _lastSensor = r;
    if (!_sensors.isClosed) _sensors.add(r);
  }

  /// Recomputes the frame rate (from the frames) and reports it to the listeners.
  void refreshFps() => setStatus(_status);

  /// Discards the frame timestamps so the frame rate reads 0 again.
  void resetFps() => _frameTimes.clear();

  Future<void> closeControllers() async {
    await _frames.close();
    await _sensors.close();
    await _statusCtrl.close();
  }
}
