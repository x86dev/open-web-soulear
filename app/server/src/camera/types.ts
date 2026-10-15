import { EventEmitter } from "node:events";
import type { SensorReading } from "./suear-protocol.ts";

export type { SensorReading };

/** Was ein Treiber kann – das Frontend blendet Bedienelemente danach ein/aus. */
export interface CameraCapabilities {
  led: boolean;
  battery: boolean;
  sensors: boolean;
}

export interface CameraStatus {
  driver: string;
  connected: boolean;
  /** Gemessene Bildrate der letzten Sekunden. */
  fps: number;
  frameCount: number;
  lastFrameAt: number | null;
  /** 0–100, null wenn unbekannt. */
  battery: number | null;
  /** 0–100, null wenn unbekannt. */
  led: number | null;
  error: string | null;
  capabilities: CameraCapabilities;
  /** Freie Geräteangaben zur Anzeige (Modell, Firmware, Auflösung …). */
  details: Record<string, string>;
}

export interface CameraDriverEvents {
  /** Ein vollständiges JPEG-Bild. */
  frame: [jpeg: Buffer];
  sensor: [reading: SensorReading];
  status: [status: CameraStatus];
}

/**
 * Probe result returned by a driver's probe method.
 * Indicates whether the driver can handle the camera at the configured IP.
 */
export interface ProbeResult {
  /** True if the driver successfully detected and can communicate with its device. */
  compatible: boolean;
  /** Optional reason if probing failed. */
  reason?: string;
}

/**
 * Driver configuration that can be read from environment and overridden by probing.
 */
export interface DriverConfig {
  cameraIp: string;
  cameraCmdPort: number;
  cameraVideoPort: number;
  cameraStreamPorts?: number[];
}

/**
 * Gemeinsame Basis aller Treiber. Ein Treiber liefert JPEG-Frames per
 * `frame`-Event; Bildrate und letzter Frame werden hier zentral gezählt.
 */
export abstract class CameraDriver extends EventEmitter<CameraDriverEvents> {
  abstract readonly name: string;
  abstract readonly capabilities: CameraCapabilities;

  protected connected = false;
  protected error: string | null = null;
  protected battery: number | null = null;
  protected led: number | null = null;
  protected details: Record<string, string> = {};
  protected config: DriverConfig;

  private frameCount = 0;
  private lastFrame: Buffer | null = null;
  private lastFrameAt: number | null = null;
  private frameTimes: number[] = [];
  private lastSensor: SensorReading | null = null;

  constructor(defaultConfig: DriverConfig) {
    super();
    this.config = defaultConfig;
  }

  abstract init(): Promise<boolean>;
  abstract destroy(): Promise<void>;

  abstract connect(): Promise<void>;
  abstract disconnect(): Promise<void>;

  /**
   * Probe the camera to determine if this driver can handle it.
   * Implementations should perform a quick, non-blocking discovery check.
   * Return immediately if the device is incompatible or unreachable.
   * Can optionally override driver config based on probing results.
   */
  abstract probe(): Promise<ProbeResult>;

  /** LED-Helligkeit 0–100. Nur wenn `capabilities.led`. */
  async setLed(_level: number): Promise<void> {
    throw new Error(`Treiber "${this.name}" unterstützt keine LED-Steuerung`);
  }

  latestFrame(): Buffer | null {
    return this.lastFrame;
  }

  latestSensor(): SensorReading | null {
    return this.lastSensor;
  }

  protected pushSensor(reading: SensorReading): void {
    this.lastSensor = reading;
    this.emit("sensor", reading);
  }

  status(): CameraStatus {
    const now = Date.now();
    this.frameTimes = this.frameTimes.filter((t) => now - t < 3000);
    return {
      driver: this.name,
      connected: this.connected,
      fps: Math.round((this.frameTimes.length / 3) * 10) / 10,
      frameCount: this.frameCount,
      lastFrameAt: this.lastFrameAt,
      battery: this.battery,
      led: this.led,
      error: this.error,
      capabilities: this.capabilities,
      details: this.details,
    };
  }

  protected pushFrame(jpeg: Buffer): void {
    const now = Date.now();
    this.frameCount++;
    this.lastFrame = jpeg;
    this.lastFrameAt = now;
    this.frameTimes.push(now);
    this.emit("frame", jpeg);
  }
}
