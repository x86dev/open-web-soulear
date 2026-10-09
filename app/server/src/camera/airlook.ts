import dgram from "node:dgram";
import {
  DeviceInfo,
  StatusReading,
  VideoFrameAssembler,
  PacketType,
  encodeDiscoveryRequest,
  encodeStartStreamingCommand,
  parseDiscoveryResponse,
  parseStatusResponse,
  parseVideoPacket,
} from "./airlook-protocol.js";
import { CameraDriver } from "./types.js";

export interface AirlookOptions {
  ip: string;
  /** Discovery und Status-Anfragen (50000). */
  cmdPort: number;
  /** Video-Stream (8032). */
  videoPort: number;
  log: (msg: string) => void;
}

/** Timeout für Discovery/Status-Anfragen. */
const REQUEST_TIMEOUT_MS = 3000;
/** Länge des Heartbeats für Video-Streaming. */
const VIDEO_HEARTBEAT_MS = 600;
/** Länge ohne Bilddaten bevor Streaming neu gestartet wird. */
const STALL_MS = 10000;
/** Abstand für Status-Polling. */
const STATUS_INTERVAL_MS = 2000;

/**
 * Treiber für AIR-Look WiFi Ear Camera (Enjoy-866, MoLink TX816, UDP-basiert).
 *
 * Ablauf: Discovery → GetStatus (Akkustand) → Video-Streaming starten →
 * Chunks empfangen und zu JPEGs zusammensetzen. Regelmäßig Heartbeat
 * senden und Status abfragen.
 */
export class AirlookDriver extends CameraDriver {
  readonly name = "airlook";
  readonly capabilities = { led: false, battery: true, sensors: false };

  private cmdSock: dgram.Socket | null = null;
  private videoSock: dgram.Socket | null = null;
  private readonly assembler = new VideoFrameAssembler();
  private lastDataAt = 0;
  private everReceived = false;
  private stallError = false;
  private restartPending = false;
  private watchdog: NodeJS.Timeout | null = null;
  private statusTimer: NodeJS.Timeout | null = null;
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private statusFailures = 0;
  private deviceInfo: DeviceInfo | null = null;

  constructor(private readonly opts: AirlookOptions) {
    super();
  }

  async connect(): Promise<void> {
    if (this.connected) return;
    this.error = null;
    this.everReceived = false;

    try {
      this.cmdSock = dgram.createSocket({ type: "udp4", reuseAddr: true });
      this.cmdSock.on('error', (err: Error) => {
        console.error('Command Socket Error:', err.message);
      });

      this.videoSock = dgram.createSocket({ type: "udp4", reuseAddr: true });
      this.videoSock.on('error', (err: Error) => {
        console.error('Video Socket Error:', err.message);
      });

      this.videoSock.on("message", (buf) => this.onVideoData(buf));

      await this.discover();
      this.opts.log(`Kamera: ${this.deviceInfo?.model || "unbekannt"}`);

      this.connected = true;
      await this.startVideo();

      this.watchdog = setInterval(() => this.checkStall(), 1000);
      this.statusTimer = setInterval(() => this.pollStatus(), STATUS_INTERVAL_MS);
      this.heartbeatTimer = setInterval(() => this.sendVideoHeartbeat(), VIDEO_HEARTBEAT_MS);
    } catch (err) {
      await this.teardown();
      this.error = (err as Error).message;
      throw err;
    }
  }

  async disconnect(): Promise<void> {
    await this.teardown();
  }

  // --- intern ---------------------------------------------------------------

  private async teardown(): Promise<void> {
    if (this.watchdog) clearInterval(this.watchdog);
    if (this.statusTimer) clearInterval(this.statusTimer);
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.watchdog = this.statusTimer = this.heartbeatTimer = null;
    this.cmdSock?.close();
    this.videoSock?.close();
    this.cmdSock = null;
    this.videoSock = null;
    this.assembler.reset();
    this.connected = false;
  }

  private async discover(): Promise<void> {
    const req = encodeDiscoveryRequest(0x1060);
    console.log(req);
    const res = await this.sendRequest(this.opts.cmdPort, req);
    const parsed = parseDiscoveryResponse(res);
    console.log(parsed);
    if (!parsed) {
      throw new Error(
        `Kamera antwortet nicht (${this.opts.ip}:${this.opts.cmdPort}). Ist dieses Gerät im WLAN der Kamera?`,
      );
    }
    const [, payload] = parsed;
    console.log('parsed: ');
    console.log(parsed);
    try {
      this.deviceInfo = JSON.parse(payload);
    } catch {
      throw new Error(`Discovery: Ungültige JSON-Antwort`);
    }
    this.details = {
      ...this.details,
      Hersteller: this.deviceInfo?.manufacturer || "unbekannt",
      Modell: this.deviceInfo?.model || "unbekannt",
      Firmware: this.deviceInfo?.firmware || "unbekannt",
      MAC: this.deviceInfo?.mac || "unbekannt",
    };
  }

  private async pollStatus(): Promise<void> {
    try {
      const req = encodeDiscoveryRequest(0x1060);
      const res = await this.sendRequest(this.opts.cmdPort, req);
      const status = parseStatusResponse(res);
      if (status) {
        this.battery = Math.min(100, Math.max(0, status.battery));
        this.details = { ...this.details, Spannung: `${status.voltage} mV` };
        this.statusFailures = 0;
        if (this.error === "Kamera antwortet nicht mehr auf Status-Abfragen") {
          this.error = null;
        }
      }
    } catch {
      if (++this.statusFailures >= 3) {
        this.error = "Kamera antwortet nicht mehr auf Status-Abfragen";
      }
    }
  }

  private async startVideo(): Promise<void> {
    const req = encodeStartStreamingCommand();
    try {
      await this.sendRequest(this.opts.videoPort, req);
      this.lastDataAt = Date.now();
      this.opts.log(`Video-Stream gestartet`);
    } catch (err) {
      throw new Error(`StartVideo fehlgeschlagen: ${(err as Error).message}`);
    }
  }

  private sendVideoHeartbeat(): void {
    if (!this.connected) return;
    const req = encodeStartStreamingCommand();
    this.cmdSock?.send(req, this.opts.videoPort, this.opts.ip, () => undefined);
  }

  private checkStall(): void {
    if (!this.connected || this.restartPending || Date.now() - this.lastDataAt < STALL_MS) return;
    this.error = this.everReceived
      ? "Bildstrom unterbrochen – starte neu"
      : "Keine Bilddaten von der Kamera";
    this.stallError = true;
    this.opts.log(this.error);
    this.lastDataAt = Date.now();
    this.restartPending = true;
    this.startVideo()
      .catch((e) => this.opts.log(`StartVideo fehlgeschlagen: ${(e as Error).message}`))
      .finally(() => (this.restartPending = false));
  }

  private onVideoData(buf: Buffer): void {
    const part = parseVideoPacket(buf);
    if (!part) return;

    this.lastDataAt = Date.now();
    if (!this.everReceived) {
      this.everReceived = true;
      this.opts.log(`Erste Bilddaten empfangen`);
    }
    if (this.stallError) {
      this.stallError = false;
      this.error = null;
    }

    for (const frame of this.assembler.push(part)) {
      this.pushFrame(frame.jpeg);
    }
  }

  /**
   * Sendet eine Anfrage und wartet auf die Antwort.
   */
  private sendRequest(port: number, data: Buffer, timeoutMs = REQUEST_TIMEOUT_MS): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const hexString = Array.from(data)
        .map(byte => byte.toString(16).padStart(2, '0').toUpperCase())
        .join(' ');
      console.log(`Payload: [ ${hexString} ]`);
      const timer = setTimeout(() => {
        reject(new Error(`Zeitüberschreitung (IP ${this.opts.ip}, Port ${port}`));
      }, timeoutMs);

      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.opts.ip) return;
        clearTimeout(timer);
        this.cmdSock?.off("message", onMessage);
        resolve(buf);
      };

      this.cmdSock?.on("message", onMessage);
      this.cmdSock?.send(data, port, this.opts.ip, (err) => {
        if (err) {
          clearTimeout(timer);
          this.cmdSock?.off("message", onMessage);
          reject(err);
        }
      });

      if (this.cmdSock?.listening) {
        this.cmdSock.on("message", onMessage);
        this.cmdSock.send(data, port, this.opts.ip, (err) => {
          if (err) {
            clearTimeout(timer);
            this.cmdSock?.off("message", onMessage);
            reject(err);
          }
        });
      }
    });
  }
}
