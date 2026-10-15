import { config } from "../config.ts";
import { MockDriver } from "./mock.ts";
import { ReplayDriver } from "./replay.ts";
import { SoulearDriver } from "./soulear.ts";
import { AirlookDriver } from "./airlook.ts";
import { AutoDriver } from "./auto.ts";
import type { CameraDriver, DriverConfig } from "./types.js";

const driverDefaults: Record<Exclude<string, "auto">, DriverConfig> = {
  mock: { cameraIp: "127.0.0.1", cameraCmdPort: 0, cameraVideoPort: 0 },
  replay: { cameraIp: "127.0.0.1", cameraCmdPort: 0, cameraVideoPort: 0 },
  soulear: {
    cameraIp: "192.168.1.1",
    cameraCmdPort: 10005,
    cameraVideoPort: 10006,
    cameraStreamPorts: [22785, 22789],
  },
  airlook: { cameraIp: "192.168.0.10", cameraCmdPort: 50000, cameraVideoPort: 8032 },
};

const driverConfig: DriverConfig = {
  cameraIp: config.cameraIp,
  cameraCmdPort: config.cameraCmdPort,
  cameraVideoPort: config.cameraVideoPort,
  cameraStreamPorts: config.cameraStreamPorts,
};

export function createDriver(log: (msg: string) => void): CameraDriver {
  switch (config.driver) {
    case "mock":
      return new MockDriver();
    case "replay":
      return new ReplayDriver(config.replayDir, config.replayFps);
    case "soulear":
      return new SoulearDriver(driverConfig, log);
    case "airlook":
      return new AirlookDriver(driverConfig, log);
    case "auto":
      return new AutoDriver(driverConfig, log);
  }
}
