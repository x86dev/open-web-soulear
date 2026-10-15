/**
 * UDP protocol for the AIR-Look WiFi Ear Camera.
 * Enjoy-866 device (MoLink TX816).
 *
 * This module defines the packet layout and helpers used by the driver,
 * including the discovery/status commands, the UDP video packet schema,
 * and the JPEG reassembly logic.
 *
 * Credits for reverse engineering: https://github.com/lockieluke/airlook-protocol
 */

export const DISCOVERY_PORT = 50000;
export const VIDEO_PORT = 8032;
export const CONTROL_PORT = 7060;

export const DISCOVERY_MAGIC = 0x9999;
export const VIDEO_MAGIC = 0x66;
export const HEADER_SIZE = 24;
export const VIDEO_HEADER_SIZE = 24;

export const MessageType = {
  DISCOVERY: 0x1060,
  STATUS: 0x1710,
} as const;

/**
 * Board-info opcode. `get_board_info` (0x1060) returns a length-prefixed JSON
 * blob (brand, model, firmware, MAC, ...).
 *
 * Reply layout (buffer offsets, after the 4-byte magic+opcode echo):
 *   [4:8]   index echo
 *   [8:12]  (unknown status word)
 *   [12:16] payload length (LE u32)
 *   [16:20] (unknown)
 *   [24:..] JSON payload (NUL-terminated)
 *
 * Source: https://github.com/tiktock/unofficial-airlook-web (analysis/opcodes.md)
 */
export const BoardInfoOpcode = {
  GetBoardInfo: 0x1060,
} as const;

/**
 * LED-control opcodes. The camera LED is driven through a PWM channel:
 * set it with [SetPwm] and read it back with [GetPwm]. On the P6X the LED is
 * binary (any non-zero value lights it as bright as 1).
 *
 * Source: https://github.com/tiktock/unofficial-airlook-web (analysis/opcodes.md)
 */
export const LedOpcode = {
  GetPwm: 0x1015,
  SetPwm: 0x1016,
} as const;

export const PacketType = {
  SOI: 0x01,
  CONT: 0x03,
  EOI: 0x02,
} as const;

/**
 * Battery opcode. `get_battery` (0x1017) is polled at ~2 Hz by the official
 * app. Response layout (after the 4-byte magic+opcode echo):
 *   [4:6]  voltage in mV (LE u16)
 *   [6]    charge-state bitfield (bit0 = charging current, bit1 = full)
 *   [12:16] v1_src - packs (percent | 0x10000) when the data is valid
 *
 * Source: https://github.com/tiktock/unofficial-airlook-web (analysis/battery.md)
 */
export const BatteryOpcode = {
  GetBattery: 0x1017,
} as const;

export interface DeviceInfo {
  factory: boolean;
  soc: string;
  ssidHead: string;
  brand: string;
  model: string;
  hardware: string;
  firmware: string;
  fwDate: string;
  mac: string;
  streamType: string;
  rotateAngle: number;
  manufacturer: string;
  deviceMode: number;
  hasBle: boolean;
}

export interface StatusReading {
  voltage: number;
  battery: number;
}

export interface VideoPacketHeader {
  magic: number;
  type: number;
  /** Frame counter, incremented once per JPEG. */
  frameId: number;
  /** Packet index within the current frame (0-based). */
  packetIndex: number;
  /** Bytes of JPEG carried by this packet. */
  payloadSize: number;
  /**
   * Packed accelerometer reading, identical in every chunk of one frame.
   * The camera samples it once per frame, so it must be carried along with
   * the frame data. Decode with [decodeAccelerometer].
   */
  accelRaw: number;
}

/** Raw accelerometer axes as packed into the chunk header. */
export interface AccelRaw {
  /** 12-bit value (0..4095). */
  x: number;
  /** 10-bit value (0..1023). */
  y: number;
  /** 10-bit value (0..1023). */
  z: number;
  /** The undecoded 32-bit word, for logging and debugging. */
  raw: number;
}

/**
 * Decodes the packed accelerometer field from a video chunk header.
 *
 * The 32-bit little-endian word at offset [16:20] packs three axes, matching
 * the official app's StreamSelf.doExecuteMJPEG():
 *
 * ```
 * bit 31           20 19         10 9            0
 *  ┌───────────────┐┌─────────────┐┌─────────────┐
 *  │   X (12 bit)  ││  Y (10 bit) ││  Z (10 bit) │
 *  └───────────────┘└─────────────┘└─────────────┘
 * ```
 *
 * The values are raw ADC counts, not gs.
 *
 * Source: https://github.com/tiktock/unofficial-airlook-web
 * (analysis/video-stream.md)
 */
export function decodeAccelerometer(raw: number): AccelRaw {
  return {
    x: (raw >>> 20) & 0xfff,
    y: (raw >>> 10) & 0x3ff,
    z: raw & 0x3ff,
    raw: raw >>> 0,
  };
}

function formatHex(buf: Buffer): string {
  return Array.from(buf)
    .map((byte) => byte.toString(16).padStart(2, "0").toUpperCase())
    .join(" ");
}

/**
 * Encodes a discovery request.
 *
 * The control packet is 24 bytes long, with the magic word at offset 0,
 * the request type at offset 2-3, and the command identifier at offset 4-5.
 */
export function encodeDiscoveryRequest(
  messageType: number = MessageType.DISCOVERY,
  cmdId: number = 0x04e2,
): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt16LE(messageType, 2);
  buf.writeUInt16LE(cmdId, 4);

  console.log(`[AIRLOOK TX] discovery request -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Encodes a status request.
 *
 * The status packet uses the same 0x9999 discovery magic and a status type
 * value in the command field, followed by a zero-filled payload area.
 */
export function encodeStatusRequest(cmdId: number = 0x04e2): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt16LE(MessageType.STATUS, 2);
  buf.writeUInt16LE(cmdId, 4);

  console.log(`[AIRLOOK TX] status request -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Encodes the UDP start-stream command used to keep the video stream alive.
 */
export function encodeStartStreamingCommand(): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt8(0x01, 2);
  buf.writeUInt8(0x00, 3);

  console.log(`[AIRLOOK TX] start stream -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Encodes a Format-B (0x9999) control packet: magic | opcode | index u32 |
 * int param u32 | 12 zero bytes. Used for the LED (PWM) commands.
 */
function encodeFormatB(opcode: number, intParam: number, index: number): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt16LE(opcode, 2);
  buf.writeUInt32LE(index >>> 0, 4);
  buf.writeUInt32LE(intParam >>> 0, 8);
  return buf;
}

/**
 * Encodes a SetPwm command that switches the LED on (value 0-100) or off
 * (value 0). Returns the packet and the index used (for response matching).
 */
export function encodeSetLed(level: number, index = 0): Buffer {
  const value = Math.max(0, Math.min(100, Math.round(level)));
  const buf = encodeFormatB(LedOpcode.SetPwm, value, index);
  console.log(`[AIRLOOK TX] set led ${value} -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Encodes a GetPwm command to read the current LED value.
 */
export function encodeGetLed(index = 0): Buffer {
  const buf = encodeFormatB(LedOpcode.GetPwm, 0, index);
  console.log(`[AIRLOOK TX] get led -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Parses a GetPwm response -> LED value (0 = off). The reply echoes magic +
 * opcode (4 bytes), then the 4-byte index echo, then the value at payload
 * offset [4:8] - i.e. buffer offset [8:12] (LE u32). Null if it does not match.
 */
export function parseLedStatus(buf: Buffer): number | null {
  if (buf.length < 12 || buf.readUInt16LE(0) !== DISCOVERY_MAGIC) return null;
  if (buf.readUInt16LE(2) !== LedOpcode.GetPwm) return null;
  return buf.readUInt32LE(8);
}

/** Encodes a get_battery command (Format B, opcode 0x1017). */
export function encodeGetBattery(index = 0): Buffer {
  const buf = encodeFormatB(BatteryOpcode.GetBattery, 0, index);
  console.log(`[AIRLOOK TX] get battery -> ${formatHex(buf)}`);
  return buf;
}

export interface BatteryReading {
  /** Voltage in mV, if the reply carried a plausible reading. */
  voltage: number | null;
  /** 0-100, or null if the firmware reports no battery telemetry. */
  percent: number | null;
  charging: boolean;
  full: boolean;
}

/**
 * Parses a get_battery response. The reply echoes magic + opcode, then the
 * payload documented in BatteryOpcode. Returns null if the reply is not a
 * matching get_battery response.
 */
export function parseBatteryResponse(buf: Buffer): BatteryReading | null {
  if (buf.length < 20 || buf.readUInt16LE(0) !== DISCOVERY_MAGIC) return null;
  if (buf.readUInt16LE(2) !== BatteryOpcode.GetBattery) return null;

  // The reply echoes magic + opcode (4 bytes) before the payload, so the
  // documented payload offsets are shifted by 4.
  const voltage = buf.readUInt16LE(8); // payload [4:6]
  const chargeByte = buf.readUInt8(10); // payload [6]
  const v1 = buf.readUInt32LE(16); // payload [12:16]
  const percent = v1 & 0x10000 ? v1 & 0xffff : null;
  return {
    voltage: voltage > 0 ? voltage : null,
    percent: percent === null ? null : Math.min(100, Math.max(0, percent)),
    charging: (chargeByte & 0x01) !== 0,
    full: (chargeByte & 0x02) !== 0,
  };
}

/**
 * Parses a discovery response.
 * The payload begins at the first JSON object brace in the reply.
 */
export function parseDiscoveryResponse(
  buf: Buffer,
): [header: Buffer, payload: string] | null {
  if (buf.length < 8 || buf.readUInt16LE(0) !== DISCOVERY_MAGIC) {
    console.log(`[AIRLOOK RX] invalid discovery response -> ${formatHex(buf)}`);
    return null;
  }

  console.log(`[AIRLOOK RX] discovery response -> ${formatHex(buf)}`);

  const header = buf.subarray(0, 6);
  const jsonStartIndex = buf.indexOf("{");
  if (jsonStartIndex === -1) {
    console.log("[AIRLOOK RX] discovery response had no JSON payload");
    return null;
  }

  const jsonString = buf.toString("utf8", jsonStartIndex);
  return [header, jsonString];
}

/** Encodes a get_board_info command (Format B, opcode 0x1060). */
export function encodeGetBoardInfo(index = 0): Buffer {
  const buf = encodeFormatB(BoardInfoOpcode.GetBoardInfo, 0, index);
  console.log(`[AIRLOOK TX] get board info -> ${formatHex(buf)}`);
  return buf;
}

/**
 * Parses a get_board_info response into the board-info JSON.
 *
 * Follows the documented layout: the payload length is a LE u32 at buffer
 * offset [12:16], and the JSON starts at buffer offset 24. Falls back to
 * "first '{' to end" if the length field looks implausible, so it also works
 * with the earlier, looser discovery parsing.
 */
export function parseBoardInfo(buf: Buffer): DeviceInfo | null {
  if (buf.length < 24 || buf.readUInt16LE(0) !== DISCOVERY_MAGIC) return null;
  if (buf.readUInt16LE(2) !== BoardInfoOpcode.GetBoardInfo) return null;

  const declared = buf.readUInt32LE(12);
  let payload: Buffer;
  if (declared > 0 && declared <= buf.length - 24) {
    payload = buf.subarray(24, 24 + declared);
  } else {
    const brace = buf.indexOf("{");
    if (brace === -1) return null;
    payload = buf.subarray(brace);
  }

  // The JSON is NUL-terminated (padded to the packet size).
  const nul = payload.indexOf(0);
  const text = payload.subarray(0, nul === -1 ? payload.length : nul).toString("utf8");
  try {
    return JSON.parse(text) as DeviceInfo;
  } catch {
    console.log(`[AIRLOOK RX] board info JSON parse error -> ${formatHex(payload.subarray(0, 48))}`);
    return null;
  }
}

/**
 * Parses the battery voltage and percentage from a status response.
 */
export function parseStatusResponse(buf: Buffer): StatusReading | null {
  if (buf.length < 24) {
    console.log(`[AIRLOOK RX] status response too short -> ${formatHex(buf)}`);
    return null;
  }

  console.log(`[AIRLOOK RX] status response -> ${formatHex(buf)}`);

  if (buf.readUInt16LE(0) !== DISCOVERY_MAGIC) {
    console.log("[AIRLOOK RX] status response magic mismatch");
    return null;
  }

  if (buf.readUInt16LE(2) !== MessageType.STATUS) {
    console.log("[AIRLOOK RX] status response type mismatch");
    return null;
  }

  const voltage = buf.readUInt16LE(8);
  const battery = buf.readUInt8(16);
  return { voltage, battery };
}

export function parseVideoPacketHeader(buf: Buffer): VideoPacketHeader | null {
  if (buf.length < VIDEO_HEADER_SIZE || buf[0] !== VIDEO_MAGIC) {
    console.log(`[AIRLOOK RX] invalid video packet -> ${formatHex(buf)}`);
    return null;
  }

  // All multi-byte fields in the chunk header are little-endian; the packed
  // accelerometer sits where a timestamp would be expected.
  return {
    magic: buf[0],
    type: buf[1],
    frameId: buf.readUInt16LE(2),
    packetIndex: buf.readUInt16LE(12),
    payloadSize: buf.readUInt16LE(14),
    accelRaw: buf.readUInt32LE(16),
  };
}

export interface VideoPart {
  type: number;
  frameId: number;
  /** Packet index within the frame (0-based). */
  packetIndex: number;
  /** Packed accelerometer word, identical in every chunk of one frame. */
  accelRaw: number;
  payload: Buffer;
}

export function parseVideoPacket(buf: Buffer): VideoPart | null {
  const header = parseVideoPacketHeader(buf);
  if (!header) {
    return null;
  }

  return {
    type: header.type,
    frameId: header.frameId,
    packetIndex: header.packetIndex,
    accelRaw: header.accelRaw,
    payload: buf.subarray(VIDEO_HEADER_SIZE),
  };
}

export interface AssembledFrame {
  frameId: number;
  jpeg: Buffer;
  /**
   * Accelerometer reading sampled once per frame on the camera side. Null for
   * frames that could not be decoded (or assembled without a first chunk).
   */
  accel: AccelRaw | null;
}

/**
 * Collects video packets into complete JPEG frames.
 * The start-of-image packet begins a frame, continuation packets append data,
 * and the end-of-image packet closes the frame.
 */
export class VideoFrameAssembler {
  private currentFrameId: number | null = null;
  private currentFrameData: Buffer[] = [];
  private currentAccel: AccelRaw | null = null;
  private currentPacketIndex: number | null = null;

  push(part: VideoPart): AssembledFrame[] {
    const result: AssembledFrame[] = [];

    if (part.type === PacketType.SOI) {
      // The accelerometer is identical across all chunks of a frame, so the
      // value carried by the first chunk represents the whole frame.
      this.currentFrameId = part.frameId;
      this.currentFrameData = [part.payload];
      this.currentAccel = decodeAccelerometer(part.accelRaw);
      this.currentPacketIndex = part.packetIndex;
      return result;
    }

    if (part.type === PacketType.CONT && this.currentFrameId === part.frameId) {
      this.currentFrameData.push(part.payload);
      this.currentPacketIndex = part.packetIndex;
      return result;
    }

    if (part.type === PacketType.EOI && this.currentFrameId === part.frameId) {
      this.currentFrameData.push(part.payload);
      const frame = Buffer.concat(this.currentFrameData);
      const start = frame.indexOf(Buffer.from([0xff, 0xd8]));
      const end = frame.lastIndexOf(Buffer.from([0xff, 0xd9]));

      if (start >= 0 && end > start) {
        const jpeg = frame.subarray(start, end + 2);
        console.log(
          `[AIRLOOK RX] assembled frame: id=${this.currentFrameId} size=${jpeg.length} bytes accel=${this.currentAccel?.raw ?? "-"}`,
        );
        result.push({ frameId: this.currentFrameId, jpeg, accel: this.currentAccel });
      }

      this.currentFrameId = null;
      this.currentFrameData = [];
      this.currentAccel = null;
      this.currentPacketIndex = null;
      return result;
    }

    if (part.frameId !== this.currentFrameId) {
      this.currentFrameId = null;
      this.currentFrameData = [];
      this.currentAccel = null;
      this.currentPacketIndex = null;
    }

    return result;
  }

  reset(): void {
    this.currentFrameId = null;
    this.currentFrameData = [];
    this.currentAccel = null;
    this.currentPacketIndex = null;
  }
}
