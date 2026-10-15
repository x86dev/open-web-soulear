/// "auto" driver: tries the known camera drivers in turn and uses the first one
/// that responds. Mirrors app/server/src/camera/auto.ts.
///
/// Order: `soulear` (Suear/Soulear protocol) -> `airlook` (AIR-Look). Only the
/// concrete drivers know their protocols; the auto driver simply forwards the
/// frames, sensor values and status of the selected driver.
library;

import 'dart:async';

import 'airlook_client.dart';
import 'camera.dart';
import 'soulear_client.dart';

class AutoClient extends BaseCameraDriver {
  AutoClient({required this.ip, this.log = _noLog});

  final String ip;
  final void Function(String) log;

  @override
  String get name => _delegate?.name ?? 'auto';

  @override
  CameraCapabilities get capabilities => _delegate?.capabilities ?? const CameraCapabilities();

  CameraDriver? _delegate;
  final _subs = <StreamSubscription<Object?>>[];

  /// Drivers in detection order (name for display/logging only).
  List<CameraDriver> _candidates() => [
        SoulearClient(config: SoulearConfig(ip: ip), log: log),
        AirlookClient(config: AirlookConfig(ip: ip), log: log),
      ];

  @override
  Future<void> connect() async {
    if (status.connected) return;
    log('[auto] Suche Kamera unter $ip …');

    final errors = <String>[];
    for (final driver in _candidates()) {
      log('[auto] Versuche ${driver.name} …');
      try {
        await driver.connect();
      } catch (e) {
        errors.add('${driver.name}: $e');
        await driver.dispose();
        continue;
      }
      await _adopt(driver);
      return;
    }

    setStatus(status.copyWith(error: 'Keine kompatible Kamera gefunden'));
    throw CameraException('Keine kompatible Kamera unter $ip gefunden (${errors.join('; ')})');
  }

  /// Adopts a connected driver: forwards streams and mirrors the current state.
  Future<void> _adopt(CameraDriver driver) async {
    _delegate = driver;
    _subs
      ..add(driver.frames.listen((f) {
        emitFrame(f);
        refreshFps();
      }))
      ..add(driver.sensors.listen(emitSensor))
      ..add(driver.statusStream.listen((s) {
        // Adopt the driver status; setStatus() sets the frame rate centrally.
        setStatus(s.copyWith(capabilities: driver.capabilities));
      }));

    setStatus(driver.status.copyWith(connected: true, capabilities: driver.capabilities));
    log('[auto] Verbunden mit ${driver.name}');
  }

  @override
  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _delegate?.disconnect();
    resetFps();
    setStatus(status.copyWith(connected: false));
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _delegate?.dispose();
    _delegate = null;
    await closeControllers();
  }

  @override
  Future<void> setLed(int level) async {
    final d = _delegate;
    if (d == null || !d.capabilities.led) {
      throw const CameraException('Dieser Kamera-Typ hat keine steuerbare LED');
    }
    await d.setLed(level);
  }
}

void _noLog(String _) {}
