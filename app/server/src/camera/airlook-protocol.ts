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

export const PacketType = {
  SOI: 0x01,
  CONT: 0x03,
  EOI: 0x02,
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
  streamId: number;
  frameId: number;
  seqNum: number;
  payloadSize: number;
  timestamp: number;
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

  const header = {
    magic: buf[0],
    type: buf[1],
    streamId: buf.readUInt16BE(2),
    frameId: buf.readUInt16BE(4),
    seqNum: buf.readUInt16BE(12),
    payloadSize: buf.readUInt16BE(14),
    timestamp: buf.readUInt32BE(16),
  };

  console.log(
    `[AIRLOOK RX] video packet: type=${header.type} frameId=${header.frameId} streamId=${header.streamId} seq=${header.seqNum} payload=${header.payloadSize} ts=${header.timestamp}`,
  );

  return header;
}

export interface VideoPart {
  type: number;
  frameId: number;
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
    payload: buf.subarray(VIDEO_HEADER_SIZE),
  };
}

export interface AssembledFrame {
  frameId: number;
  jpeg: Buffer;
}

/**
 * Collects video packets into complete JPEG frames.
 * The start-of-image packet begins a frame, continuation packets append data,
 * and the end-of-image packet closes the frame.
 */
export class VideoFrameAssembler {
  private currentFrameId: number | null = null;
  private currentFrameData: Buffer[] = [];

  push(part: VideoPart): AssembledFrame[] {
    const result: AssembledFrame[] = [];

    if (part.type === PacketType.SOI) {
      this.currentFrameId = part.frameId;
      this.currentFrameData = [part.payload];
      return result;
    }

    if (part.type === PacketType.CONT && this.currentFrameId === part.frameId) {
      this.currentFrameData.push(part.payload);
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
          `[AIRLOOK RX] assembled frame: id=${this.currentFrameId} size=${jpeg.length} bytes`,
        );
        result.push({ frameId: this.currentFrameId, jpeg });
      }

      this.currentFrameId = null;
      this.currentFrameData = [];
      return result;
    }

    if (part.frameId !== this.currentFrameId) {
      this.currentFrameId = null;
      this.currentFrameData = [];
    }

    return result;
  }

  reset(): void {
    this.currentFrameId = null;
    this.currentFrameData = [];
  }
}
