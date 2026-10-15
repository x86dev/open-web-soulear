/*
 * Driver for the AIR-Look WiFi Ear Camera.
 * Enjoy-866 device (MoLink TX816).
 *
 * Credits for reverse engineering: https://github.com/lockieluke/airlook-protocol
 */

import dgram from "node:dgram";
import net from "node:net";
import {
  parseDiscoveryResponse,
  parseVideoPacket,
  VideoFrameAssembler,
  encodeDiscoveryRequest,
  encodeStartStreamingCommand,
  encodeSetLed,
  encodeGetLed,
  parseLedStatus,
  encodeGetBattery,
  parseBatteryResponse,
  encodeGetBoardInfo,
  parseBoardInfo,
  DISCOVERY_PORT,
  VIDEO_PORT,
  CONTROL_PORT,
  type DeviceInfo,
} from "./airlook-protocol.ts";
import { CameraDriver, type DriverConfig, type ProbeResult } from "./types.js";
import { SensorSmoother } from "./suear-protocol.ts";

const REQUEST_TIMEOUT_MS = 3000;
const PROBE_TIMEOUT_MS = 1500;
const VIDEO_HEARTBEAT_MS = 600;
const STATUS_POLL_MS = 1800;

/**
 * AIR-Look WiFi Ear Camera driver.
 *
 * The driver follows the same control-flow pattern as the device protocol:
 * discovery request, status polling, stream start command, periodic heartbeat,
 * and JPEG reassembly from UDP video packets.
 */
export class AirlookDriver extends CameraDriver {
  readonly name = "airlook";
  readonly capabilities = { led: true, battery: true, sensors: true };

  private cmdSock: dgram.Socket | null = null;
  private videoSock: dgram.Socket | null = null;
  private tcpSock: net.Socket | null = null;
  private readonly assembler = new VideoFrameAssembler();
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private statusTimer: NodeJS.Timeout | null = null;
  private deviceInfo: DeviceInfo | null = null;
  /** Monotonic index for Format-B requests (LED). */
  private seq = 0;
  private ledLogged = false;

  /**
   * Smooths the per-frame accelerometer readings, same filtering as the
   * soulear driver (libWifiCamera's sensor_get_xyz).
   */
  private readonly smoother = new SensorSmoother();

  constructor(
    config: DriverConfig,
    private log: (msg: string) => void,
  ) {
    super(config);
  }

  async init(): Promise<boolean> {
    this.error = null;

    this.cmdSock = dgram.createSocket({ type: "udp4", reuseAddr: true });
    this.cmdSock.on("error", (err: Error) => {
      console.error("[AIRLOOK] command socket error:", err.message);
      return false;
    });

    this.videoSock = dgram.createSocket({ type: "udp4", reuseAddr: true });
    this.videoSock.on("error", (err: Error) => {
      console.error("[AIRLOOK] video socket error:", err.message);
      return false;
    });

    this.videoSock.on("message", (buf) => this.onVideoData(buf));

    this.cmdSock.bind(0);
    this.videoSock.bind(0);

    return true;
  }

  async destroy(): Promise<void> {
    return;
  }

  async probe(): Promise<ProbeResult> {
    try {
      const req = encodeDiscoveryRequest();
      const res = await this.probeRequest(
        this.config.cameraCmdPort,
        req,
        PROBE_TIMEOUT_MS,
      );
      const parsed = parseDiscoveryResponse(res);

      if (!parsed) {
        return { compatible: false, reason: "Invalid discovery response" };
      }

      console.log(`[AIRLOOK] probe success`);
      return { compatible: true };
    } catch (err) {
      console.log(`[AIRLOOK] probe failed: ${(err as Error).message}`);
      return {
        compatible: false,
        reason: (err as Error).message,
      };
    }
  }

  async connect(): Promise<void> {
    if (this.connected) {
      return;
    }

    try {
      await this.discover();
      this.log(`Camera: ${this.deviceInfo?.model ?? "unknown"}`);

      this.connected = true;
      this.connectTcp();
      this.startVideo();

      // Read the LED state once immediately, so the UI matches the device
      // (the LED is on at power-on) instead of waiting for the first poll.
      await this.readLed().catch(() => undefined);

      this.heartbeatTimer = setInterval(() => this.sendVideoHeartbeat(), VIDEO_HEARTBEAT_MS);
      this.statusTimer = setInterval(() => this.pollStatus(), STATUS_POLL_MS);
    } catch (err) {
      await this.disconnect();
      this.error = (err as Error).message;
      throw err;
    }
  }

  async disconnect(): Promise<void> {
    this.connected = false;

    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }

    if (this.statusTimer) {
      clearInterval(this.statusTimer);
      this.statusTimer = null;
    }

    this.tcpSock?.destroy();
    this.tcpSock = null;

    this.cmdSock?.close();
    this.videoSock?.close();
    this.cmdSock = null;
    this.videoSock = null;
    this.assembler.reset();
  }

  private async discover(): Promise<void> {
    const req = encodeGetBoardInfo(++this.seq);
    const res = await this.sendRequest(this.config.cameraCmdPort, req);
    const info = parseBoardInfo(res);

    if (!info) {
      throw new Error(
        `Camera did not respond (${this.config.cameraIp}:${this.config.cameraCmdPort}).`,
      );
    }

    this.deviceInfo = info;
    console.log("[AIRLOOK] board info:", info);

    // Build a readable detail set for the device tab. Only include non-empty
    // fields so the UI does not show blank rows.
    const entries: Record<string, string> = {
      manufacturer: info.manufacturer || info.brand || "unknown",
      model: info.model || "unknown",
      hardware: info.hardware,
      firmware: info.firmware,
      fwDate: info.fwDate,
      soc: info.soc,
      mac: info.mac,
      streamType: info.streamType,
    };
    this.details = {
      ...this.details,
      ...Object.fromEntries(Object.entries(entries).filter(([, v]) => v !== "")),
    };
  }

  private async pollStatus(): Promise<void> {
    try {
      // get_battery (0x1017) carries voltage, charge state and percentage.
      const res = await this.sendFormatB(encodeGetBattery(++this.seq));
      const battery = res ? parseBatteryResponse(res) : null;

      if (battery) {
        if (battery.percent !== null) this.battery = battery.percent;
        this.details = {
          ...this.details,
          ...(battery.voltage !== null ? { voltage: `${battery.voltage} mV` } : {}),
          Laden: battery.charging ? "ja" : "nein",
        };
        this.error = null;
        console.log(
          `[AIRLOOK] battery: voltage=${battery.voltage ?? "?"} mV ` +
            `percent=${battery.percent ?? "?"}% charging=${battery.charging} full=${battery.full}`,
        );
      }
    } catch (err) {
      console.warn("[AIRLOOK] status poll failed:", (err as Error).message);
    }

    // Read the LED state alongside the battery (best effort).
    await this.readLed().catch(() => undefined);
  }

  /**
   * Sets the LED brightness 0-100 (0 = off). The command travels on the
   * control port as a Format-B 0x9999 packet (opcode 0x1016, value in the int
   * slot). On the P6X the LED is binary, so any non-zero value looks the same.
   */
  /**
   * Sets the LED. The AIR-Look LED is binary (off = 0, on = any non-zero
   * value), so any requested level > 0 is sent as 1. The command travels on the
   * control port as a Format-B 0x9999 packet (opcode 0x1016).
   */
  override async setLed(level: number): Promise<void> {
    const value = level > 0 ? 1 : 0;
    const res = await this.sendFormatB(encodeSetLed(value, ++this.seq));
    if (!res) throw new Error("SetLed: no response from the camera");
    this.led = value;
    // Align the display with the actual state, like the soulear driver does.
    await this.readLed().catch(() => undefined);
  }

  /** Reads the LED value from the camera (GetPwm 0x1015); keeps the old value on failure. */
  private async readLed(): Promise<void> {
    const res = await this.sendFormatB(encodeGetLed(++this.seq));
    const raw = res ? parseLedStatus(res) : null;
    if (!this.ledLogged) {
      this.ledLogged = true;
      console.log(`[AIRLOOK] LED query -> ${res ? res.toString("hex") : "(no response)"} => ${raw ?? "unreadable"}`);
    }
    // The LED is binary: 0 = off, any non-zero value = on.
    if (raw !== null) this.led = raw > 0 ? 1 : 0;
  }

  /** Sends a Format-B packet on the command socket and returns the raw reply. */
  private sendFormatB(packet: Buffer): Promise<Buffer | null> {
    return new Promise((resolve) => {
      const sock = this.cmdSock;
      if (!sock) {
        resolve(null);
        return;
      }
      const port = this.config.cameraCmdPort;
      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp) return;
        cleanup();
        resolve(buf);
      };
      const timer = setTimeout(() => {
        cleanup();
        resolve(null);
      }, REQUEST_TIMEOUT_MS);
      const cleanup = () => {
        clearTimeout(timer);
        sock.off("message", onMessage);
      };
      sock.on("message", onMessage);
      sock.send(packet, port, this.config.cameraIp, (err) => {
        if (err) {
          cleanup();
          resolve(null);
        }
      });
    });
  }

  private startVideo(): void {
    const port = this.config.cameraVideoPort ?? VIDEO_PORT;
    const req = encodeStartStreamingCommand();
    this.videoSock?.send(req, port, this.config.cameraIp, (err) => {
      if (err) {
        console.error("[AIRLOOK] start video send error:", err.message);
      }
    });
  }

  private sendVideoHeartbeat(): void {
    if (!this.connected) {
      return;
    }

    const port = this.config.cameraVideoPort ?? VIDEO_PORT;
    const req = encodeStartStreamingCommand();
    this.videoSock?.send(req, port, this.config.cameraIp, (err) => {
      if (err) {
        console.error("[AIRLOOK] heartbeat send error:", err.message);
      }
    });
  }

  private connectTcp(): void {
    const controlPort = CONTROL_PORT;
    let attempts = 0;

    const tryConnect = (): void => {
      if (!this.connected || attempts >= 5) {
        return;
      }

      const sock = net.createConnection({ host: this.config.cameraIp, port: controlPort });
      sock.setTimeout(2000);

      sock.once("connect", () => {
        this.tcpSock = sock;
        this.log(`TCP connected to port ${controlPort}`);
        console.log(`[AIRLOOK] tcp connected to ${this.config.cameraIp}:${controlPort}`);
      });

      sock.on("error", () => {
        console.warn(`[AIRLOOK] TCP connection failed to ${this.config.cameraIp}:${controlPort}`);
        sock.destroy();
        attempts += 1;
        if (this.connected) {
          setTimeout(tryConnect, 1000);
        }
      });

      sock.on("close", () => {
        if (this.tcpSock === sock) {
          this.tcpSock = null;
        }
      });
    };

    tryConnect();
  }

  private onVideoData(buf: Buffer): void {
    if (buf.length < 24 || buf[0] !== 0x66) {
      return;
    }

    const part = parseVideoPacket(buf);
    if (!part) {
      return;
    }

    for (const frame of this.assembler.push(part)) {
      this.pushFrame(frame.jpeg);

      // The accelerometer travels in the video chunk header (one sample per
      // frame), so it is the only sensor source for this camera. The header
      // carries no flag bytes, hence the empty flags tuple.
      if (frame.accel) {
        this.pushSensor(
          this.smoother.push([frame.accel.x, frame.accel.y, frame.accel.z], [0, 0]),
        );
      }
    }
  }

  private sendRequest(
    port: number,
    data: Buffer,
    timeoutMs = REQUEST_TIMEOUT_MS,
  ): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Request timed out while talking to ${this.config.cameraIp}:${port}`));
      }, timeoutMs);

      const cleanup = () => {
        clearTimeout(timer);
        this.cmdSock?.off("message", onMessage);
      };

      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp) {
          return;
        }

        console.log(
          `[AIRLOOK RX] request response from ${rinfo.address}:${rinfo.port} -> ${buf.length} bytes`,
        );
        cleanup();
        resolve(buf);
      };

      this.cmdSock?.once("message", onMessage);
      this.cmdSock?.send(data, port, this.config.cameraIp, (err) => {
        if (err) {
          cleanup();
          console.error("[AIRLOOK] UDP send failed:", err.message);
          reject(err);
        }
      });
    });
  }

  private probeRequest(
    port: number,
    data: Buffer,
    timeoutMs: number,
  ): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const sock = dgram.createSocket({ type: "udp4" });
      const timer = setTimeout(() => {
        sock.close();
        reject(new Error("probe timeout"));
      }, timeoutMs);

      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp) {
          return;
        }

        clearTimeout(timer);
        sock.close();
        resolve(buf);
      };

      sock.once("message", onMessage);
      sock.once("error", () => {
        clearTimeout(timer);
        sock.close();
        reject(new Error("socket error"));
      });

      sock.send(data, port, this.config.cameraIp, (err) => {
        if (err) {
          clearTimeout(timer);
          sock.close();
          reject(err);
        }
      });
    });
  }
}
