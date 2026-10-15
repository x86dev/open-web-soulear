import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soulear_local/src/camera.dart';
import 'package:soulear_local/src/protocol.dart';

/// Minimal driver, only to test the central frame-rate logic of the base class.
/// `fps` belongs to the base class and is derived from the frames - drivers do
/// not set it themselves.
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
  test('fps belongs to the base class and follows the frames', () async {
    final d = _FakeDriver();
    await d.connect();
    expect(d.fps, 0);

    // 30 frames in quick succession -> about 10 fps over the 3 s window.
    for (var i = 0; i < 30; i++) {
      d.feedFrame();
    }
    d.refreshFps();
    expect(d.fps, greaterThan(0));
    expect(d.status.fps, d.fps);
  });

  test('resetFps zeroes the frame rate and disconnect cleans up', () async {
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
