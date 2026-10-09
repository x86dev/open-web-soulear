/**
 * UDP-Protokoll für AIR-Look WiFi Ear Camera (Enjoy-866, MoLink TX816).
 *
 * Quellen: Wireshark pcap-Analyse der iOS-App (com.air.airlook).
 * Alle numerischen Felder little-endian, außer wo explizit angegeben.
 */

export const DISCOVERY_MAGIC = 0x9999;
export const VIDEO_MAGIC = 0x66;
export const HEADER_SIZE = 24;
export const VIDEO_HEADER_SIZE = 24;

export const MessageType = {
  Discover: 0x1017,
  GetStatus: 0x1017,
  GetInfo: 0x1060,
} as const;

export const PacketType = {
  SOI: 0x01,  // Start Of Image
  CONT: 0x03, // Continuation
  EOI: 0x02,  // End Of Image
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
  voltage: number;    // Millivolts
  battery: number;    // Percentage 0–100
}

export interface VideoPacketHeader {
  magic: number;
  type: number;       // SOI | CONT | EOI
  streamId: number;
  frameId: number;
  seqNum: number;
  payloadSize: number;
  timestamp: number;
}

/**
 * Kodiert eine Discovery/GetStatus-Anfrage (24 Byte).
 * Typ ist little-endian u16 an Offset 2–3.
 */
export function encodeDiscoveryRequest(
  messageType: number,
  cmdId: number = 0x04e2,
): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt16LE(messageType, 2);
  buf.writeUInt16LE(cmdId, 4);
  // Offset 6–23: Nullen (Padding)
  return buf;
}

/**
 * Dekodiert eine Discovery-Antwort.
 * Rückgabe: [Header (6 Byte), JSON-Payload als String].
 */
export function parseDiscoveryResponse(buf: Buffer): [header: Buffer, payload: string] | null {
  if (buf.length < 8 || buf.readUInt16LE(0) !== DISCOVERY_MAGIC) {
    return null;
  }
  const header = buf.subarray(0, 6);
  const jsonStartIndex = buf.indexOf('{');
  if (jsonStartIndex === -1) {
    return null;
  }
  const jsonString = buf.toString('utf8', jsonStartIndex);
  return [header, jsonString];
}

/**
 * Dekodiert eine Status-Antwort (Spannungs-/Akkupegel).
 * Format: 6 Byte Header + Status-Daten (2 unbekannt + 2 Spannung + 6 unbekannt
 * + 1 Akkuprozent + 7 unbekannt).
 */
export function parseStatusResponse(buf: Buffer): StatusReading | null {
  if (buf.length < 24) return null;
  // Offset 8–9: Spannung in mV (little-endian u16)
  const voltage = buf.readUInt16LE(8);
  // Offset 16: Akkuprozent (u8)
  const battery = buf.readUInt8(16);
  return { voltage, battery };
}

/**
 * Kodiert das "Start Streaming"-Kommando für UDP 8032 (24 Byte).
 */
export function encodeStartStreamingCommand(): Buffer {
  const buf = Buffer.alloc(HEADER_SIZE);
  buf.writeUInt16LE(DISCOVERY_MAGIC, 0);
  buf.writeUInt8(0x01, 2);
  // Offset 3–23: Nullen (Padding)
  return buf;
}

/**
 * Dekodiert einen Video-Packet-Header (erste 24 Byte eines Video-Packets).
 */
export function parseVideoPacketHeader(buf: Buffer): VideoPacketHeader | null {
  if (buf.length < VIDEO_HEADER_SIZE || buf[0] !== VIDEO_MAGIC) {
    return null;
  }
  return {
    magic: buf[0],
    type: buf[1],
    streamId: buf.readUInt16BE(2),
    frameId: buf.readUInt16BE(4),
    seqNum: buf.readUInt16BE(12),
    payloadSize: buf.readUInt16BE(14),
    timestamp: buf.readUInt32BE(16),
  };
}

export interface VideoPart {
  type: number;
  frameId: number;
  payload: Buffer;
}

/**
 * Parst einen Video-Packet aus einem UDP-Datagramm.
 * Rückgabe: VideoPart oder null.
 */
export function parseVideoPacket(buf: Buffer): VideoPart | null {
  const header = parseVideoPacketHeader(buf);
  if (!header) return null;
  const payload = buf.subarray(VIDEO_HEADER_SIZE);
  return {
    type: header.type,
    frameId: header.frameId,
    payload,
  };
}

export interface AssembledFrame {
  frameId: number;
  jpeg: Buffer;
}

/**
 * Sammelt Video-Packets zu vollständigen JPEG-Frames.
 * Robust gegen Umordnung: SOI leitet neuen Frame ein, EOI schliesst ihn ab.
 */
export class VideoFrameAssembler {
  private pendingFrames = new Map<number, Buffer>();
  private currentFrameId: number | null = null;
  private currentFrameData: Buffer[] = [];

  /**
   * Gibt fertige Frames zurück (meist 0 oder 1).
   */
  push(part: VideoPart): AssembledFrame[] {
    const result: AssembledFrame[] = [];

    if (part.type === PacketType.SOI) {
      // Neuer Frame beginnt – alten verwerfen falls vorhanden
      this.currentFrameId = part.frameId;
      this.currentFrameData = [part.payload];
    } else if (part.type === PacketType.CONT && this.currentFrameId === part.frameId) {
      this.currentFrameData.push(part.payload);
    } else if (part.type === PacketType.EOI && this.currentFrameId === part.frameId) {
      this.currentFrameData.push(part.payload);
      const jpeg = Buffer.concat(this.currentFrameData);
      // Validierung: Starts mit FFD8, endet mit FFD9
      if (jpeg.length >= 4 && jpeg[0] === 0xff && jpeg[1] === 0xd8 &&
          jpeg[jpeg.length - 2] === 0xff && jpeg[jpeg.length - 1] === 0xd9) {
        result.push({ frameId: this.currentFrameId, jpeg });
      }
      this.currentFrameId = null;
      this.currentFrameData = [];
    }

    return result;
  }

  reset(): void {
    this.pendingFrames.clear();
    this.currentFrameId = null;
    this.currentFrameData = [];
  }
}
