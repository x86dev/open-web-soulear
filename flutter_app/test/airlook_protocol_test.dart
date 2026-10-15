import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soulear_local/src/airlook_protocol.dart';

/// Baut ein Videopaket, wie die AIR-Look-Kamera es sendet (Header laut
/// airlook-protocol.ts, big-endian).
Uint8List makeVideoPacket(int type, int frameId, List<int> payload) {
  final b = ByteData(videoHeaderSize);
  b.setUint8(0, videoMagic);
  b.setUint8(1, type);
  b.setUint16(2, 1, Endian.big); // streamId
  b.setUint16(4, frameId, Endian.big);
  b.setUint16(12, 0, Endian.big); // seqNum
  b.setUint16(14, payload.length, Endian.big); // payloadSize
  b.setUint32(16, 0, Endian.big); // timestamp
  return Uint8List.fromList([...b.buffer.asUint8List(), ...payload]);
}

void main() {
  test('Discovery-Anfrage: Magic, Typ, Kommando', () {
    final r = encodeDiscoveryRequest();
    final b = ByteData.sublistView(r);
    expect(r.length, headerSize);
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), AirMessageType.discovery);
    expect(b.getUint16(4, Endian.little), 0x04e2);
  });

  test('Status-Anfrage nutzt den Statustyp', () {
    final b = ByteData.sublistView(encodeStatusRequest());
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), AirMessageType.status);
  });

  test('Discovery-Antwort lesen (JSON ab Klammer auf)', () {
    final payload = jsonEncode({'model': 'Enjoy-866', 'firmware': '1.2.3', 'mac': 'AA:BB'});
    final buf = Uint8List.fromList([
      0x99, 0x99, 0x60, 0x10, 0xe2, 0x04, // Kopf
      ...utf8.encode(payload),
    ]);
    final parsed = parseDiscoveryResponse(buf)!;
    expect(parsed.$2, payload);
    final info = AirDeviceInfo.fromJson(jsonDecode(parsed.$2) as Map<String, dynamic>);
    expect(info.model, 'Enjoy-866');
    expect(info.firmware, '1.2.3');
    expect(info.mac, 'AA:BB');
  });

  test('Status-Antwort: Spannung und Akku', () {
    final buf = ByteData(24)
      ..setUint16(0, discoveryMagic, Endian.little)
      ..setUint16(2, AirMessageType.status, Endian.little)
      ..setUint16(8, 3980, Endian.little) // Spannung mV
      ..setUint8(16, 73); // Akku %
    final s = parseStatusResponse(buf.buffer.asUint8List())!;
    expect(s.voltage, 3980);
    expect(s.battery, 73);
    expect(parseStatusResponse(Uint8List(4)), isNull);
  });

  test('Videopaket parsen (Big-Endian-Header)', () {
    final p = parseVideoPacket(makeVideoPacket(PacketType.soi, 42, [1, 2, 3]))!;
    expect(p.type, PacketType.soi);
    expect(p.frameId, 42);
    expect(p.payload, [1, 2, 3]);
    expect(parseVideoPacket(Uint8List.fromList([0x00, ...Uint8List(30)])), isNull);
  });

  test('JPEG aus SOI/CONT/EOI zusammensetzen', () {
    final a = VideoFrameAssembler();
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.soi, 7, [0xff, 0xd8, 0x10]))!), isNull);
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.cont, 7, [0x20, 0x30]))!), isNull);
    final frame = a.push(parseVideoPacket(makeVideoPacket(PacketType.eoi, 7, [0x40, 0xff, 0xd9]))!)!;
    expect(frame.frameId, 7);
    expect(frame.jpeg, [0xff, 0xd8, 0x10, 0x20, 0x30, 0x40, 0xff, 0xd9]);
  });

  test('Fremde CONT/EOI ohne SOI werden verworfen', () {
    final a = VideoFrameAssembler();
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.cont, 1, [0x10]))!), isNull);
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.eoi, 1, [0xff, 0xd9]))!), isNull);
  });
}
