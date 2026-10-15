import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
/** app/ – funktioniert aus src/ (tsx) und dist/ (node) gleichermaßen. */
const appRoot = path.resolve(here, "..", "..");

function env(name: string, fallback: string): string {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : v;
}

export type DriverName = "auto" | "mock" | "replay" | "soulear" | "airlook";

const driver = env("DRIVER", "auto");
if (!["auto", "mock", "replay", "soulear", "airlook"].includes(driver)) {
  throw new Error(
    `Unbekannter DRIVER "${driver}" (erlaubt: auto, mock, replay, soulear, airlook)`,
  );
}

const driverDefaults: Record<Exclude<DriverName, "auto">, { cameraIp: string; cameraCmdPort: number; cameraVideoPort: number; cameraStreamPorts?: number[] }> = {
  mock: { cameraIp: "127.0.0.1", cameraCmdPort: 0, cameraVideoPort: 0 },
  replay: { cameraIp: "127.0.0.1", cameraCmdPort: 0, cameraVideoPort: 0 },
  soulear: { cameraIp: "192.168.1.1", cameraCmdPort: 10005, cameraVideoPort: 10006, cameraStreamPorts: [22785, 22789] },
  airlook: { cameraIp: "192.168.0.10", cameraCmdPort: 50000, cameraVideoPort: 8032 },
};

const defaults =
  driver === "auto"
    ? driverDefaults.soulear
    : driverDefaults[driver as Exclude<DriverName, "auto">];

export const config = {
  host: env("HOST", "127.0.0.1"),
  port: Number(env("PORT", "3000")),
  driver: driver as DriverName,
  /** Zielordner für Fotos. */
  mediaDir: path.resolve(env("MEDIA_DIR", path.join(appRoot, "media"))),
  /** Gebautes Frontend, wird statisch ausgeliefert (falls vorhanden). */
  webDist: path.join(appRoot, "web", "dist"),

  /** replay: Ordner mit JPEG-Frames (z. B. aus `npm run pcap -- extract-jpeg`). */
  replayDir: path.resolve(env("REPLAY_DIR", path.join(appRoot, "captures", "frames"))),
  replayFps: Number(env("REPLAY_FPS", "15")),

  /** soulear/airlook/auto: Kamera im Kamera-WLAN. Defaults je nach DRIVER. */
  cameraIp: env("CAMERA_IP", defaults.cameraIp),
  cameraCmdPort: Number(env("CAMERA_CMD_PORT", String(defaults.cameraCmdPort))),
  cameraVideoPort: Number(env("CAMERA_VIDEO_PORT", String(defaults.cameraVideoPort))),

  /** Lokale UDP-Ports für den Bildstrom, der erste wird der Kamera mitgeteilt. */
  cameraStreamPorts: env("STREAM_PORTS", "22785,22789")
    .split(",")
    .map((p) => Number(p.trim())),
};
