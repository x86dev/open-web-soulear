import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soulear_local/src/airlook_protocol.dart';

/// Builds a video packet the way the AIR-Look camera sends it (24-byte
/// little-endian header, accel packed at [16:20]).
Uint8List makeVideoPacket(int type, int frameId, List<int> payload, {int accelRaw = 0}) {
  final b = ByteData(videoHeaderSize);
  b.setUint8(0, videoMagic);
  b.setUint8(1, type);
  b.setUint16(2, frameId, Endian.little);
  b.setUint16(12, 0, Endian.little); // packet index
  b.setUint16(14, payload.length, Endian.little); // payload size
  b.setUint32(16, accelRaw, Endian.little); // packed accelerometer
  return Uint8List.fromList([...b.buffer.asUint8List(), ...payload]);
}

void main() {
  test('discovery request: magic, type, command', () {
    final r = encodeDiscoveryRequest();
    final b = ByteData.sublistView(r);
    expect(r.length, headerSize);
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), AirMessageType.discovery);
    expect(b.getUint16(4, Endian.little), 0x04e2);
  });

  test('status request uses the status type', () {
    final b = ByteData.sublistView(encodeStatusRequest());
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), AirMessageType.status);
  });

  test('discovery response parsed (JSON from the opening brace)', () {
    final payload = jsonEncode({'model': 'Enjoy-866', 'firmware': '1.2.3', 'mac': 'AA:BB'});
    final buf = Uint8List.fromList([
      0x99, 0x99, 0x60, 0x10, 0xe2, 0x04, // header
      ...utf8.encode(payload),
    ]);
    final parsed = parseDiscoveryResponse(buf)!;
    expect(parsed.$2, payload);
    final info = AirDeviceInfo.fromJson(jsonDecode(parsed.$2) as Map<String, dynamic>);
    expect(info.model, 'Enjoy-866');
    expect(info.firmware, '1.2.3');
    expect(info.mac, 'AA:BB');
  });

  test('status response: voltage and battery', () {
    final buf = ByteData(24)
      ..setUint16(0, discoveryMagic, Endian.little)
      ..setUint16(2, AirMessageType.status, Endian.little)
      ..setUint16(8, 3980, Endian.little) // voltage mV
      ..setUint8(16, 73); // battery %
    final s = parseStatusResponse(buf.buffer.asUint8List())!;
    expect(s.voltage, 3980);
    expect(s.battery, 73);
    expect(parseStatusResponse(Uint8List(4)), isNull);
  });

  test('video packet parsed (little-endian header)', () {
    final p = parseVideoPacket(makeVideoPacket(PacketType.soi, 42, [1, 2, 3]))!;
    expect(p.type, PacketType.soi);
    expect(p.frameId, 42);
    expect(p.packetIndex, 0);
    expect(p.payload, [1, 2, 3]);
    expect(parseVideoPacket(Uint8List.fromList([0x00, ...Uint8List(30)])), isNull);
  });

  test('accelerometer decoded from the packed chunk-header word', () {
    final raw = (100 << 20) | (200 << 10) | 300;
    final p = parseVideoPacket(makeVideoPacket(PacketType.soi, 1, const [], accelRaw: raw))!;
    expect(p.accelRaw, raw);
    final a = decodeAccelerometer(p.accelRaw);
    expect(a.x, 100);
    expect(a.y, 200);
    expect(a.z, 300);

    // Axis limits: X is 12-bit, Y/Z are 10-bit.
    final max = decodeAccelerometer(0xffffffff);
    expect(max.x, 0xfff);
    expect(max.y, 0x3ff);
    expect(max.z, 0x3ff);
  });

  test('JPEG assembled from SOI/CONT/EOI', () {
    final a = VideoFrameAssembler();
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.soi, 7, [0xff, 0xd8, 0x10]))!), isNull);
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.cont, 7, [0x20, 0x30]))!), isNull);
    final frame = a.push(parseVideoPacket(makeVideoPacket(PacketType.eoi, 7, [0x40, 0xff, 0xd9]))!)!;
    expect(frame.frameId, 7);
    expect(frame.jpeg, [0xff, 0xd8, 0x10, 0x20, 0x30, 0x40, 0xff, 0xd9]);
  });

  test('assembled frame carries the first chunk\'s accelerometer', () {
    final raw = (11 << 20) | (22 << 10) | 33;
    final a = VideoFrameAssembler();
    expect(
      a.push(parseVideoPacket(makeVideoPacket(PacketType.soi, 7, [0xff, 0xd8], accelRaw: raw))!),
      isNull,
    );
    final frame = a.push(
      parseVideoPacket(makeVideoPacket(PacketType.eoi, 7, [0xff, 0xd9])),
    )!;
    expect(frame.accel.x, 11);
    expect(frame.accel.y, 22);
    expect(frame.accel.z, 33);
  });

  test('foreign CONT/EOI without SOI are dropped', () {
    final a = VideoFrameAssembler();
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.cont, 1, [0x10]))!), isNull);
    expect(a.push(parseVideoPacket(makeVideoPacket(PacketType.eoi, 1, [0xff, 0xd9]))!), isNull);
  });

  test('battery response: voltage, percent, charge state', () {
    // Real packet example from analysis/battery.md: 3961 mV, discharging, 86%.
    final payload = <int>[
      0x0b, 0x00, 0x00, 0x00, // idx echo
      0x79, 0x0f, // voltage mV = 3961
      0x00, // charge byte: discharging
      0x05, // battery present
      0x40, 0x00, 0x00, 0x00, // status word
      0x56, 0x00, 0x01, 0x00, // v1_src = 0x00010056 -> percent 0x56 = 86
    ];
    final buf = Uint8List.fromList([
      0x99, 0x99, 0x17, 0x10, // magic + opcode 0x1017
      ...payload,
    ]);
    final b = parseBatteryResponse(buf)!;
    expect(b.voltage, 3961);
    expect(b.percent, 86);
    expect(b.charging, isFalse);
    expect(b.full, isFalse);

    // validity bit clear -> no percent reported
    final noPctPayload = [...payload];
    noPctPayload[12] = 0x00;
    noPctPayload[13] = 0x00; // v1_src low byte, bit 16 (0x10000) not set
    noPctPayload[14] = 0x00;
    noPctPayload[15] = 0x00;
    final noPct = Uint8List.fromList([0x99, 0x99, 0x17, 0x10, ...noPctPayload]);
    expect(parseBatteryResponse(noPct)!.percent, isNull);

    // wrong opcode -> null
    expect(parseBatteryResponse(Uint8List.fromList([0x99, 0x99, 0x15, 0x10, ...payload])), isNull);
  });

  test('board info parsed from a getBoardInfo reply (length-prefixed JSON)', () {
    const json = '{"brand":"JesHome","model":"P6X","firmware":"1.0.0","mac":"AA:BB:CC:DD:EE:FF"}';
    final jsonBytes = utf8.encode(json);
    final buf = Uint8List(24 + jsonBytes.length + 1);
    final b = ByteData.sublistView(buf);
    b.setUint16(0, discoveryMagic, Endian.little);
    b.setUint16(2, BoardInfoOpcode.getBoardInfo, Endian.little);
    b.setUint32(4, 5, Endian.little); // index echo
    b.setUint32(12, jsonBytes.length, Endian.little); // payload length
    buf.setRange(24, 24 + jsonBytes.length, jsonBytes); // NUL padding follows
    final info = parseBoardInfo(buf)!;
    expect(info.brand, 'JesHome');
    expect(info.model, 'P6X');
    expect(info.firmware, '1.0.0');
    expect(info.mac, 'AA:BB:CC:DD:EE:FF');

    // implausible length -> falls back to scanning for '{'
    b.setUint32(12, 999999, Endian.little);
    expect(parseBoardInfo(buf)!.model, 'P6X');

    // wrong magic -> null
    expect(parseBoardInfo(Uint8List(64)), isNull);
  });

  test('set LED encodes Format B (magic, opcode 0x1016, value)', () {
    final p = encodeSetLed(100, 0x11223344);
    final b = ByteData.sublistView(p);
    expect(p.length, headerSize);
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), LedOpcode.setPwm);
    expect(b.getUint32(4, Endian.little), 0x11223344); // index
    expect(b.getUint32(8, Endian.little), 100); // value
    // off
    expect(ByteData.sublistView(encodeSetLed(0)).getUint32(8, Endian.little), 0);
    // clamped
    expect(ByteData.sublistView(encodeSetLed(250)).getUint32(8, Endian.little), 100);
  });

  test('get LED encodes Format B with opcode 0x1015', () {
    final b = ByteData.sublistView(encodeGetLed(7));
    expect(b.getUint16(0, Endian.little), discoveryMagic);
    expect(b.getUint16(2, Endian.little), LedOpcode.getPwm);
    expect(b.getUint32(4, Endian.little), 7);
    expect(b.getUint32(8, Endian.little), 0);
  });

  test('LED status parsed from a GetPwm reply', () {
    final buf = ByteData(24)
      ..setUint16(0, discoveryMagic, Endian.little)
      ..setUint16(2, LedOpcode.getPwm, Endian.little)
      ..setUint32(4, 9999, Endian.little) // index echo
      ..setUint32(8, 42, Endian.little); // value
    expect(parseLedStatus(buf.buffer.asUint8List()), 42);
    // wrong opcode / too short -> null
    final wrong = ByteData(24)
      ..setUint16(0, discoveryMagic, Endian.little)
      ..setUint16(2, LedOpcode.setPwm, Endian.little);
    expect(parseLedStatus(wrong.buffer.asUint8List()), isNull);
    expect(parseLedStatus(Uint8List(4)), isNull);
  });
}
