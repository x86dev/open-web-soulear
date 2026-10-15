/// Testet den Kamera-Treiber ohne App – gegen die echte Kamera oder die
/// simulierte aus app/ (`npm run fake-camera`).
///
///   dart run tool/probe.dart [Treiber] [IP] [Sekunden]
///   dart run tool/probe.dart soulear 127.0.0.1 5   # simulierte Kamera
///   dart run tool/probe.dart auto                  # echte Kamera, Treiber raten
///   dart run tool/probe.dart                       # Standard: auto, 192.168.1.1
///
/// Treiber: auto (Standard), soulear, airlook.
library;

import 'dart:io';

import 'package:soulear_local/src/airlook_client.dart';
import 'package:soulear_local/src/auto_client.dart';
import 'package:soulear_local/src/camera.dart';
import 'package:soulear_local/src/protocol.dart';
import 'package:soulear_local/src/soulear_client.dart';

Future<void> main(List<String> args) async {
  final driver = args.isNotEmpty ? args[0] : 'auto';
  final ip = args.length > 1 ? args[1] : '192.168.1.1';
  final seconds = args.length > 2 ? int.parse(args[2]) : 5;

  void log(String m) => stdout.writeln('  [client] $m');

  final CameraDriver client = switch (driver) {
    'soulear' => SoulearClient(config: SoulearConfig(ip: ip), log: log),
    'airlook' => AirlookClient(config: AirlookConfig(ip: ip), log: log),
    _ => AutoClient(ip: ip, log: log),
  };

  var frames = 0;
  var bytes = 0;
  SensorReading? sensor;
  client.frames.listen((f) {
    frames++;
    bytes += f.jpeg.length;
  });
  client.sensors.listen((s) => sensor = s);

  try {
    await client.connect();
  } catch (e) {
    stderr.writeln('Verbinden fehlgeschlagen: $e');
    await client.dispose();
    exit(1);
  }
  stdout.writeln('Verbunden (${client.name}): ${client.status.details}');

  await Future<void>.delayed(Duration(seconds: seconds));
  stdout.writeln('Bilder: $frames in $seconds s (${(frames / seconds).toStringAsFixed(1)} fps), '
      'Ø ${frames == 0 ? 0 : bytes ~/ frames} Byte');
  final s = sensor;
  if (s != null) {
    stdout.writeln('Sensor: Drehung ${s.roll}°, Neigung ${s.pitch}°, roh ${s.x}/${s.y}/${s.z}');
  }

  if (client.capabilities.led) {
    await client.setLed(0);
    stdout.writeln('LED nach Aus: ${client.status.led}');
    await client.setLed(100);
    stdout.writeln('LED nach An: ${client.status.led}');
  } else {
    stdout.writeln('LED: nicht unterstützt');
  }

  await client.dispose();
  exit(frames > 0 ? 0 : 2);
}
