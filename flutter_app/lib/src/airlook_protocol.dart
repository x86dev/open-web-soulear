/// UDP protocol of the AIR-Look WiFi ear camera (Enjoy-866, MoLink TX816).
///
/// Dart port of app/server/src/camera/airlook-protocol.ts - see there for the
/// packet layout and sources.
///
/// Credits for reverse-engineering:
///   https://github.com/lockieluke/airlook-protocol.
///
/// All control fields are little-endian, the video packets big-endian.
/// Pure Dart, no Flutter.
library;

import 'dart:convert';
import 'dart:typed_data';

const int discoveryPort = 50000;
const int videoPort = 8032;
const int controlPort = 7060;

const int discoveryMagic = 0x9999;
const int videoMagic = 0x66;
const int headerSize = 24;
const int videoHeaderSize = 24;

abstract final class AirMessageType {
  static const discovery = 0x1060;
  static const status = 0x1710;
}

/// Board-info opcode. `getBoardInfo` (0x1060) returns a length-prefixed JSON
/// blob (brand, model, firmware, MAC, ...).
///
/// Reply layout (buffer offsets, after the 4-byte magic+opcode echo):
///   [4:8]   index echo
///   [8:12]  (unknown status word)
///   [12:16] payload length (LE u32)
///   [16:20] (unknown)
///   [24:..] JSON payload (NUL-terminated)
///
/// Source: https://github.com/tiktock/unofficial-airlook-web (analysis/opcodes.md)
abstract final class BoardInfoOpcode {
  static const getBoardInfo = 0x1060;
}

/// LED-control opcodes. The camera LED is driven through a PWM channel:
/// set it with [setPwm] and read it back with [getPwm]. On the P6X the LED is
/// binary (any non-zero value lights it as bright as 1).
///
/// Source: https://github.com/tiktock/unofficial-airlook-web (analysis/opcodes.md)
abstract final class LedOpcode {
  static const getPwm = 0x1015;
  static const setPwm = 0x1016;
}

abstract final class PacketType {
  static const soi = 0x01; // Start of image
  static const cont = 0x03; // continuation
  static const eoi = 0x02; // End of image
}

/// Battery opcode. `getBattery` (0x1017) is polled at ~2 Hz by the official
/// app. Response layout (after the 4-byte magic+opcode echo):
///   [4:6]   voltage in mV (LE u16)
///   [6]     charge-state bitfield (bit0 = charging current, bit1 = full)
///   [12:16] v1_src - packs (percent | 0x10000) when the data is valid
///
/// Source: https://github.com/tiktock/unofficial-airlook-web (analysis/battery.md)
abstract final class BatteryOpcode {
  static const getBattery = 0x1017;
}

class AirDeviceInfo {
  const AirDeviceInfo({
    this.factory = false,
    this.soc = '',
    this.ssidHead = '',
    this.brand = '',
    this.model = '',
    this.hardware = '',
    this.firmware = '',
    this.fwDate = '',
    this.mac = '',
    this.streamType = '',
    this.rotateAngle = 0,
    this.manufacturer = '',
    this.deviceMode = 0,
    this.hasBle = false,
  });

  final bool factory;
  final String soc;
  final String ssidHead;
  final String brand;
  final String model;
  final String hardware;
  final String firmware;
  final String fwDate;
  final String mac;
  final String streamType;
  final int rotateAngle;
  final String manufacturer;
  final int deviceMode;
  final bool hasBle;

  factory AirDeviceInfo.fromJson(Map<String, dynamic> j) => AirDeviceInfo(
        factory: j['factory'] == true,
        soc: '${j['soc'] ?? ''}',
        ssidHead: '${j['ssidHead'] ?? j['ssid_head'] ?? ''}',
        brand: '${j['brand'] ?? ''}',
        model: '${j['model'] ?? ''}',
        hardware: '${j['hardware'] ?? j['hw'] ?? ''}',
        firmware: '${j['firmware'] ?? j['fw'] ?? ''}',
        fwDate: '${j['fwDate'] ?? j['fw_date'] ?? ''}',
        mac: '${j['mac'] ?? ''}',
        streamType: '${j['streamType'] ?? j['stream_type'] ?? ''}',
        rotateAngle: (j['rotateAngle'] ?? j['rotate_angle'] ?? 0) is num
            ? (j['rotateAngle'] ?? j['rotate_angle'] ?? 0).toInt()
            : 0,
        manufacturer: '${j['manufacturer'] ?? j['brand'] ?? ''}',
        deviceMode: (j['deviceMode'] ?? j['device_mode'] ?? 0) is num
            ? (j['deviceMode'] ?? j['device_mode'] ?? 0).toInt()
            : 0,
        hasBle: j['hasBle'] == true || j['has_ble'] == true,
      );
}

class AirStatus {
  const AirStatus(this.voltage, this.battery);
  final int voltage;
  final int battery;
}

/// Discovery request: 24 bytes, magic at 0, type at 2-3, command at 4-5.
Uint8List encodeDiscoveryRequest([int messageType = AirMessageType.discovery, int cmdId = 0x04e2]) {
  final buf = ByteData(headerSize);
  buf.setUint16(0, discoveryMagic, Endian.little);
  buf.setUint16(2, messageType, Endian.little);
  buf.setUint16(4, cmdId, Endian.little);
  return buf.buffer.asUint8List();
}

/// Status request: same magic, status type in the command field.
Uint8List encodeStatusRequest([int cmdId = 0x04e2]) {
  final buf = ByteData(headerSize);
  buf.setUint16(0, discoveryMagic, Endian.little);
  buf.setUint16(2, AirMessageType.status, Endian.little);
  buf.setUint16(4, cmdId, Endian.little);
  return buf.buffer.asUint8List();
}

/// Start command for the video stream (also repeated as a heartbeat).
Uint8List encodeStartStreamingCommand() {
  final buf = ByteData(headerSize);
  buf.setUint16(0, discoveryMagic, Endian.little);
  buf.setUint8(2, 0x01);
  buf.setUint8(3, 0x00);
  return buf.buffer.asUint8List();
}

/// Encodes a Format-B (0x9999) control packet: magic | opcode | index u32 |
/// int parameter u32 | 12 zero bytes. Used for the LED (PWM) commands.
Uint8List _encodeFormatB(int opcode, int intParam, int index) {
  final buf = ByteData(headerSize);
  buf.setUint16(0, discoveryMagic, Endian.little);
  buf.setUint16(2, opcode, Endian.little);
  buf.setUint32(4, index & 0xffffffff, Endian.little);
  buf.setUint32(8, intParam & 0xffffffff, Endian.little);
  return buf.buffer.asUint8List();
}

/// SetPwm command: switches the LED on (value 1-100) or off (value 0).
Uint8List encodeSetLed(int level, [int index = 0]) {
  final value = level.clamp(0, 100);
  return _encodeFormatB(LedOpcode.setPwm, value, index);
}

/// GetPwm command: reads the current LED value.
Uint8List encodeGetLed([int index = 0]) => _encodeFormatB(LedOpcode.getPwm, 0, index);

/// Parses a GetPwm response -> LED value (0 = off). The reply echoes magic +
/// opcode (4 bytes), then the 4-byte index echo, then the value at payload
/// offset [4:8] - i.e. buffer offset [8:12] (LE u32). Null if it does not match.
int? parseLedStatus(Uint8List buf) {
  if (buf.length < 12) return null;
  final b = ByteData.sublistView(buf);
  if (b.getUint16(0, Endian.little) != discoveryMagic) return null;
  if (b.getUint16(2, Endian.little) != LedOpcode.getPwm) return null;
  return b.getUint32(8, Endian.little);
}

/// Encodes a getBattery command (Format B, opcode 0x1017).
Uint8List encodeGetBattery([int index = 0]) => _encodeFormatB(BatteryOpcode.getBattery, 0, index);

class BatteryReading {
  const BatteryReading({this.voltage, this.percent, this.charging = false, this.full = false});

  /// Voltage in mV, or null if the reply carried no plausible reading.
  final int? voltage;

  /// 0-100, or null if the firmware reports no battery telemetry.
  final int? percent;
  final bool charging;
  final bool full;
}

/// Parses a getBattery response. The reply echoes magic + opcode (4 bytes),
/// then the payload documented at [BatteryOpcode], so payload offsets are
/// shifted by 4. Null if it does not match.
BatteryReading? parseBatteryResponse(Uint8List buf) {
  if (buf.length < 20) return null;
  final b = ByteData.sublistView(buf);
  if (b.getUint16(0, Endian.little) != discoveryMagic) return null;
  if (b.getUint16(2, Endian.little) != BatteryOpcode.getBattery) return null;

  final voltage = b.getUint16(8, Endian.little); // payload [4:6]
  final chargeByte = b.getUint8(10); // payload [6]
  final v1 = b.getUint32(16, Endian.little); // payload [12:16]
  final percent = (v1 & 0x10000) != 0 ? (v1 & 0xffff) : null;
  return BatteryReading(
    voltage: voltage > 0 ? voltage : null,
    percent: percent?.clamp(0, 100),
    charging: (chargeByte & 0x01) != 0,
    full: (chargeByte & 0x02) != 0,
  );
}

/// Parses a discovery response: [header, JSON payload] - JSON starts at '{'.
(int, String)? parseDiscoveryResponse(Uint8List buf) {
  if (buf.length < 8 || ByteData.sublistView(buf).getUint16(0, Endian.little) != discoveryMagic) {
    return null;
  }
  final jsonStartIndex = buf.indexOf(0x7b); // '{'
  if (jsonStartIndex == -1) return null;
  final jsonString = utf8.decode(buf.sublist(jsonStartIndex), allowMalformed: true);
  return (ByteData.sublistView(buf).getUint16(2, Endian.little), jsonString);
}

/// Encodes a getBoardInfo command (Format B, opcode 0x1060).
Uint8List encodeGetBoardInfo([int index = 0]) => _encodeFormatB(BoardInfoOpcode.getBoardInfo, 0, index);

/// Parses a getBoardInfo response into the board-info JSON.
///
/// Follows the documented layout: the payload length is a LE u32 at buffer
/// offset [12:16], and the JSON starts at buffer offset 24. Falls back to
/// "first '{' to end" if the length field looks implausible.
AirDeviceInfo? parseBoardInfo(Uint8List buf) {
  if (buf.length < 24) return null;
  final b = ByteData.sublistView(buf);
  if (b.getUint16(0, Endian.little) != discoveryMagic) return null;
  if (b.getUint16(2, Endian.little) != BoardInfoOpcode.getBoardInfo) return null;

  final declared = b.getUint32(12, Endian.little);
  Uint8List payload;
  if (declared > 0 && declared <= buf.length - 24) {
    payload = Uint8List.sublistView(buf, 24, 24 + declared);
  } else {
    final brace = buf.indexOf(0x7b); // '{'
    if (brace == -1) return null;
    payload = Uint8List.sublistView(buf, brace);
  }

  // The JSON is NUL-terminated (padded to the packet size).
  final nul = payload.indexOf(0);
  final text = utf8.decode(nul == -1 ? payload : payload.sublist(0, nul), allowMalformed: true);
  try {
    return AirDeviceInfo.fromJson(jsonDecode(text) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

/// Parses voltage (mV) and battery level (%) from a status response.
AirStatus? parseStatusResponse(Uint8List buf) {
  if (buf.length < 24) return null;
  final b = ByteData.sublistView(buf);
  if (b.getUint16(0, Endian.little) != discoveryMagic) return null;
  if (b.getUint16(2, Endian.little) != AirMessageType.status) return null;
  return AirStatus(b.getUint16(8, Endian.little), b.getUint8(16));
}

class VideoPart {
  const VideoPart(this.type, this.frameId, this.payload);
  final int type;
  final int frameId;
  final Uint8List payload;
}

/// Header (24 Byte, big-endian): magic u8 | type u8 | streamId u16 | frameId u16
/// | … | seqNum u16 (12) | payloadSize u16 (14) | timestamp u32 (16).
VideoPart? parseVideoPacket(Uint8List buf) {
  if (buf.length < videoHeaderSize || buf[0] != videoMagic) return null;
  final b = ByteData.sublistView(buf);
  return VideoPart(
    b.getUint8(1),
    b.getUint16(4, Endian.big),
    Uint8List.sublistView(buf, videoHeaderSize),
  );
}

class AirFrame {
  const AirFrame(this.frameId, this.jpeg);
  final int frameId;
  final Uint8List jpeg;
}

/// Assembles video packets into complete JPEG frames: SOI begins, CONT
/// appends, EOI closes the frame.
class VideoFrameAssembler {
  int? _currentFrameId;
  List<Uint8List> _currentFrameData = [];

  AirFrame? push(VideoPart part) {
    if (part.type == PacketType.soi) {
      _currentFrameId = part.frameId;
      _currentFrameData = [part.payload];
      return null;
    }

    if (part.type == PacketType.cont && _currentFrameId == part.frameId) {
      _currentFrameData.add(part.payload);
      return null;
    }

    if (part.type == PacketType.eoi && _currentFrameId == part.frameId) {
      _currentFrameData.add(part.payload);
      final frame = _concat(_currentFrameData);
      _currentFrameId = null;
      _currentFrameData = [];

      final start = _indexOfSoi(frame);
      final end = _lastIndexOfEoi(frame);
      if (start >= 0 && end > start) {
        final id = part.frameId;
        return AirFrame(id, Uint8List.sublistView(frame, start, end + 2));
      }
      return null;
    }

    if (part.frameId != _currentFrameId) {
      _currentFrameId = null;
      _currentFrameData = [];
    }
    return null;
  }

  void reset() {
    _currentFrameId = null;
    _currentFrameData = [];
  }
}

Uint8List _concat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

int _indexOfSoi(Uint8List b) {
  for (var i = 0; i + 1 < b.length; i++) {
    if (b[i] == 0xff && b[i + 1] == 0xd8) return i;
  }
  return -1;
}

int _lastIndexOfEoi(Uint8List b) {
  for (var i = b.length - 2; i >= 0; i--) {
    if (b[i] == 0xff && b[i + 1] == 0xd9) return i;
  }
  return -1;
}
