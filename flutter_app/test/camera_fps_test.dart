import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soulear_local/src/camera.dart';
import 'package:soulear_local/src/protocol.dart';

/// Minimaler Treiber, nur um die zentrale Bildraten-Logik der Basisklasse zu
/// prüfen. `fps` gehört zur Basisklasse und wird aus den Frames abgeleitet –
/// Treiber setzen es nicht selbst.
class _FakeDriver extends BaseCameraDriver {
  @override
  String get name => 'fake';
  @override
  CameraCapabilities get capabilities => const CameraCapabilities();
  @override
  Future<void> connect() async => setStatus(const CameraStatus(connected: true));
  @override
  Future<void> disconnect() async {
    resetFps();
    setStatus(const CameraStatus());
  }

  @override
  Future<void> dispose() async => disconnect();
  @override
  Future<void> setLed(int level) async {}

  void feedFrame() => emitFrame(Frame(Uint8List(2), 1, 1, (0, 0, 0), (0, 0)));
}

void main() {
  test('fps gehört zur Basisklasse und folgt den Frames', () async {
    final d = _FakeDriver();
    await d.connect();
    expect(d.fps, 0);

    // 30 Bilder kurz hintereinander -> über das 3-s-Fenster ~10 fps.
    for (var i = 0; i < 30; i++) {
      d.feedFrame();
    }
    d.refreshFps();
    expect(d.fps, greaterThan(0));
    expect(d.status.fps, d.fps);
  });

  test('resetFps setzt die Bildrate auf 0 und disconnect räumt auf', () async {
    final d = _FakeDriver();
    await d.connect();
    for (var i = 0; i < 10; i++) {
      d.feedFrame();
    }
    d.refreshFps();
    expect(d.fps, greaterThan(0));

    await d.disconnect();
    expect(d.fps, 0);
  });
}
