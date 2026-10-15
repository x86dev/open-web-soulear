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
  parseStatusResponse,
  parseVideoPacket,
  VideoFrameAssembler,
  encodeDiscoveryRequest,
  encodeStartStreamingCommand,
  encodeStatusRequest,
  DISCOVERY_PORT,
  VIDEO_PORT,
  CONTROL_PORT,
  type DeviceInfo,
} from "./airlook-protocol.ts";
import { CameraDriver, type DriverConfig, type ProbeResult } from "./types.js";

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
  readonly capabilities = { led: false, battery: true, sensors: false };

  private cmdSock: dgram.Socket | null = null;
  private videoSock: dgram.Socket | null = null;
  private tcpSock: net.Socket | null = null;
  private readonly assembler = new VideoFrameAssembler();
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private statusTimer: NodeJS.Timeout | null = null;
  private deviceInfo: DeviceInfo | null = null;

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
    const req = encodeDiscoveryRequest();
    const res = await this.sendRequest(this.config.cameraCmdPort, req);
    const parsed = parseDiscoveryResponse(res);

    if (!parsed) {
      throw new Error(
        `Camera did not respond (${this.config.cameraIp}:${this.config.cameraCmdPort}).`,
      );
    }

    try {
      this.deviceInfo = JSON.parse(parsed[1]) as DeviceInfo;
      console.log("[AIRLOOK] discovery payload:", this.deviceInfo);
    } catch (err) {
      console.error("[AIRLOOK] discovery JSON parse error:", err);
      throw new Error("Discovery: invalid JSON response");
    }

    this.details = {
      ...this.details,
      manufacturer: this.deviceInfo?.manufacturer ?? "unknown",
      model: this.deviceInfo?.model ?? "unknown",
      firmware: this.deviceInfo?.firmware ?? "unknown",
      mac: this.deviceInfo?.mac ?? "unknown",
    };
  }

  private async pollStatus(): Promise<void> {
    try {
      const req = encodeStatusRequest();
      const res = await this.sendStatusRequest(this.config.cameraCmdPort, req);
      const status = parseStatusResponse(res);

      if (!status) {
        return;
      }

      this.battery = Math.min(100, Math.max(0, status.battery));
      this.details = {
        ...this.details,
        voltage: `${status.voltage} mV`,
      };
      this.error = null;
      console.log(`[AIRLOOK] status: voltage=${status.voltage} mV battery=${status.battery}%`);
    } catch (err) {
      console.warn("[AIRLOOK] status poll failed:", (err as Error).message);
    }
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

  private sendStatusRequest(
    port: number,
    data: Buffer,
    timeoutMs = REQUEST_TIMEOUT_MS,
  ): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const sock = dgram.createSocket({ type: "udp4" });
      const timer = setTimeout(() => {
        sock.close();
        reject(new Error(`Status request timed out while talking to ${this.config.cameraIp}:${port}`));
      }, timeoutMs);

      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp) {
          return;
        }

        console.log(
          `[AIRLOOK RX] status response from ${rinfo.address}:${rinfo.port} -> ${buf.length} bytes`,
        );
        clearTimeout(timer);
        sock.close();
        resolve(buf);
      };

      sock.once("message", onMessage);
      sock.once("error", (err) => {
        clearTimeout(timer);
        sock.close();
        console.error("[AIRLOOK] status socket error:", err.message);
        reject(err);
      });

      sock.send(data, port, this.config.cameraIp, (err) => {
        if (err) {
          clearTimeout(timer);
          sock.close();
          console.error("[AIRLOOK] status send failed:", err.message);
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
