import { SoulearDriver } from "./soulear.ts";
import { AirlookDriver } from "./airlook.ts";
import { CameraDriver, type DriverConfig, type ProbeResult } from "./types.ts";

/**
 * AutoDriver probes multiple camera drivers to automatically detect which
 * device is available and select the appropriate driver.
 * The first driver that successfully probes wins.
 */
export class AutoDriver extends CameraDriver {
  readonly name = "auto";
  readonly capabilities = { led: false, battery: false, sensors: false };

  private delegate: CameraDriver | null = null;

  constructor(
    config: DriverConfig,
    private log: (msg: string) => void,
  ) {
    super(config);
  }

  async init(): Promise<boolean> {
    return true;
  }

  async destroy(): Promise<void> {
    return;
  }

  async probe(): Promise<ProbeResult> {
    // AutoDriver always claims to be compatible; the real probe happens on connect.
    return { compatible: true };
  }

  async connect(): Promise<void> {
    if (this.connected) {
      return;
    }

    this.log("[AUTO] Probing cameras...");

    const drivers = [
      new SoulearDriver(this.config, this.log),
      new AirlookDriver(this.config, this.log),
    ];

    for (const driver of drivers) {
      this.log(`[AUTO] Trying ${driver.name}...`);
      await driver.init();
      const result = await driver.probe();

      if (result.compatible) {
        this.log(`[AUTO] Found compatible camera: ${driver.name}`);
        this.delegate = driver;

        // Forward events from the delegate driver.
        this.delegate.on("frame", (jpeg) => this.pushFrame(jpeg));
        this.delegate.on("sensor", (reading) => this.pushSensor(reading));
        this.delegate.on("status", () => undefined);

        // Update our capabilities and details from the delegate.
        Object.assign(this, { capabilities: driver.capabilities });

        try {
          await this.delegate.connect();
          this.connected = true;
          this.log(`[AUTO] Connected using ${driver.name} driver`);
          return;
        } catch (err) {
          this.log(`[AUTO] Failed to connect with ${driver.name}: ${(err as Error).message}`);
          this.delegate.off("frame", () => undefined);
          this.delegate.off("sensor", () => undefined);
          this.delegate = null;
        }
      }

      driver.destroy();
    }

    this.error = "No compatible camera found";
    throw new Error(this.error);
  }

  async disconnect(): Promise<void> {
    if (this.delegate) {
      await this.delegate.disconnect();
      this.delegate = null;
    }
    this.connected = false;
  }

  override async setLed(level: number): Promise<void> {
    if (!this.delegate) {
      throw new Error("Not connected");
    }
    return this.delegate.setLed(level);
  }

  override latestFrame() {
    return this.delegate?.latestFrame() ?? null;
  }

  override latestSensor() {
    return this.delegate?.latestSensor() ?? null;
  }

  override status() {
    if (!this.delegate) {
      return super.status();
    }
    return this.delegate.status();
  }
}
