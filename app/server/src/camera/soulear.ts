import dgram from "node:dgram";
import {
  decodeMessage,
  encodeMessage,
  FrameAssembler,
  ledPayload,
  ledQueryPayload,
  MsgType,
  parseLedStatus,
  parseChunks,
  parseDeviceInfo,
  SensorSmoother,
  type Message,
} from "./suear-protocol.ts";
import { CameraDriver, type DriverConfig, type ProbeResult } from "./types.js";

/** Ohne Bilddaten so lange warten, bevor OpenVideo erneut gesendet wird. */
const STALL_MS = 6000;
const INFO_INTERVAL_MS = 10000;
const INFO_LOST = "Kamera antwortet nicht mehr auf Statusabfragen";
const PROBE_TIMEOUT_MS = 1500;
/**
 * Wie lange der bevorzugte Bild-Port gehalten/erneut versucht wird, bevor auf
 * die übrigen Ports zurückgefallen wird. Der erste Port ist der, den Kameras
 * in der Regel erwarten – ein belegter Port ist oft nur ein Rest des vorigen
 * Prozesses, der nach kurzer Zeit verschwindet.
 */
const STREAM_PORT_RETRY_MS = 3000;
const STREAM_PORT_RETRY_INTERVAL_MS = 250;

/**
 * Treiber für Soulear/Suear-Kameras (UDP, siehe suear-protocol.ts).
 *
 * Ablauf: GetDeviceInfo (Erreichbarkeit + Akku) → Bild-Ports öffnen →
 * OpenVideo → Chunks empfangen und zu JPEGs zusammensetzen. Bleiben Daten
 * aus, wird OpenVideo wiederholt – zuerst mit dem eigenen Empfangsport als
 * Nutzlast (wie libWifiCamera.so aus Soulear), dann ohne (wie ältere
 * Suear-Firmware, die fest an 22785/22789 sendet).
 */
export class SoulearDriver extends CameraDriver {
  readonly name = "soulear";
  readonly capabilities = { led: true, battery: true, sensors: true };

  private cmdSock: dgram.Socket | null = null;
  private streamSocks: dgram.Socket[] = [];
  private msgId = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private readonly assembler = new FrameAssembler();
  private readonly smoother = new SensorSmoother();
  private openMode: "port" | "plain" = "port";
  private lastDataAt = 0;
  private everReceived = false;
  /** `error` stammt vom Stall-Watchdog und wird bei neuen Daten gelöscht. */
  private stallError = false;
  private restartPending = false;
  private watchdog: NodeJS.Timeout | null = null;
  private infoTimer: NodeJS.Timeout | null = null;
  private infoFailures = 0;
  private ledLogged = false;
  /**
   * Ports der Kamera, von denen gerade eine Befehlsantwort erwartet wird.
   * Datagramme dieser Quellports auf dem Befehls-Socket sind keine Bilddaten.
   */
  private readonly pendingReplyPorts = new Set<number>();
  /** In Reihenfolge erfolgreich gebundene Bild-Ports; der erste wird beworben. */
  private boundStreamPorts: number[] = [];

  constructor(
    config: DriverConfig,
    private log: (msg: string) => void,
  ) {
    super(config);
  }

  async init(): Promise<boolean> {
    this.error = null;
    this.cmdSock = await bindUdp(0);
    // Wie in der Handy-App: die Kamera schickt den Bildstrom an den Quellport
    // der OpenVideo-Anfrage – also an genau diesen Socket. Deshalb hier sowohl
    // Befehlsantworten als auch Bilddaten verarbeiten.
    const cmdLocalPort = this.cmdSock.address().port;
    this.cmdSock.on("message", (buf, rinfo) => {
      // Nur echte, zur offenen Anfrage passende Antworten aussortieren. Bild-
      // Chunks (kein gültiger Nachrichten-Header) dürfen NIE verschluckt werden.
      if (this.isCommandReply(buf, rinfo)) return; // wird von requestOnce verarbeitet
      this.onStreamData(buf, rinfo, cmdLocalPort);
    });
    return true;
  }

  async destroy(): Promise<void> {
    await this.teardown();
    return;
  }

  async probe(): Promise<ProbeResult> {
    try {
      const packet = encodeMessage(0, MsgType.GetDeviceInfo);
      const res = await this.probeRequest(this.config.cameraCmdPort, packet, PROBE_TIMEOUT_MS);
      const decoded = decodeMessage(res);

      if (!decoded || decoded.type !== MsgType.GetDeviceInfo) {
        return { compatible: false, reason: "Invalid device info response" };
      }

      const info = parseDeviceInfo(decoded.data);
      if (!info) {
        return { compatible: false, reason: "Could not parse device info" };
      }

      console.log(`[SOULEAR] probe success: ${info.vendor} ${info.product}`);
      return { compatible: true };
    } catch (err) {
      console.log(`[SOULEAR] probe failed: ${(err as Error).message}`);
      return {
        compatible: false,
        reason: (err as Error).message,
      };
    }
  }

  async connect(): Promise<void> {
    if (this.connected)
      return;

    // Jede Verbindung wie ein frischer Client beginnen.
    this.everReceived = false;
    this.openMode = "port";
    this.boundStreamPorts = [];

    try {
      const info = await this.updateInfo().catch(() => {
        throw new Error(
          `Kamera antwortet nicht (${this.config.cameraIp}:${this.config.cameraCmdPort}). Ist dieses Gerät im WLAN der Kamera?`,
        );
      });
      this.log(`Kamera: ${info}`);

      await this.openStreamSockets();
      this.connected = true;
      await this.openVideo();

      // Wie die Original-App: nach dem Verbinden Licht an.
      await this.setLed(100).catch((e) => this.log(`LED einschalten fehlgeschlagen: ${(e as Error).message}`));

      this.watchdog = setInterval(() => this.checkStall(), 1000);
      this.infoTimer = setInterval(() => this.pollInfo(), INFO_INTERVAL_MS);
    } catch (err) {
      await this.teardown();
      this.error = (err as Error).message;
      throw err;
    }
  }

  async disconnect(): Promise<void> {
    await this.teardown();
  }

  override async setLed(level: number): Promise<void> {
    const res = await this.request(this.config.cameraCmdPort, MsgType.SetLed, ledPayload(level));
    if (res.errCode !== 0) throw new Error(`SetLed: Fehlercode ${res.errCode}`);
    this.led = Math.max(0, Math.min(100, Math.round(level)));
    // Anzeige nach dem tatsächlichen Zustand der Kamera richten.
    await this.readLed().catch(() => undefined);
  }

  /** Liest den LED-Zustand von der Kamera; bei unlesbarer Antwort bleibt der alte Wert. */
  private async readLed(): Promise<void> {
    const res = await this.request(this.config.cameraCmdPort, MsgType.SetLed, ledQueryPayload());
    const level = parseLedStatus(res.data);
    if (!this.ledLogged) {
      this.ledLogged = true;
      this.log(`LED-Abfrage: Antwort ${res.data.toString("hex") || "(leer)"} → ${level ?? "unlesbar"}`);
    }
    if (level !== null) this.led = level;
  }

  // --- intern ---------------------------------------------------------------

  private async teardown(): Promise<void> {
    if (this.watchdog) clearInterval(this.watchdog);
    if (this.infoTimer) clearInterval(this.infoTimer);
    this.watchdog = this.infoTimer = null;
    for (const s of [this.cmdSock, ...this.streamSocks]) s?.removeAllListeners();
    for (const s of [this.cmdSock, ...this.streamSocks]) s?.close();
    this.cmdSock = null;
    this.streamSocks = [];
    this.assembler.reset();
    this.smoother.reset();
    this.pendingReplyPorts.clear();
    this.boundStreamPorts = [];
    this.connected = false;
  }

  private async updateInfo(): Promise<string> {
    const res = await this.request(this.config.cameraCmdPort, MsgType.GetDeviceInfo);
    const info = parseDeviceInfo(res.data);
    if (!info) throw new Error(`GetDeviceInfo: unerwartete Antwort (${res.data.length} Byte)`);
    this.battery = Math.min(100, info.battery);
    this.details = {
      ...this.details,
      Hersteller: info.vendor,
      Modell: info.product,
      Firmware: info.firmware,
      SSID: info.ssid,
      Laden: info.charging ? "ja" : "nein",
    };
    return `${info.vendor} ${info.product} ${info.firmware}, Akku ${info.battery} %`;
  }

  private async pollInfo(): Promise<void> {
    try {
      await this.updateInfo();
      await this.readLed().catch(() => undefined);
      this.infoFailures = 0;
      if (this.error === INFO_LOST) this.error = null;
    } catch {
      if (++this.infoFailures >= 3) this.error = INFO_LOST;
    }
  }

  private async openStreamSockets(): Promise<void> {
    this.boundStreamPorts = [];
    const ports = this.config.cameraStreamPorts ?? [];

    // Bevorzugten Port zuerst – und über das Zeitfenster hinweg erneut versuchen,
    // damit ein gerade noch belegter Port (Prozessrest, Neustart) den Bildstrom
    // nicht auf einen Port umleitet, den die Kamera nicht kennt.
    for (const port of ports) {
      const sock = await this.bindStreamPort(port, this.boundStreamPorts.length === 0);
      if (sock) return; // erster erfolgreich gebundener Port wird beworben
    }
    throw new Error(`Keiner der Bild-Ports ${ports.join("/")} ist frei`);
  }

  /**
   * Bindet einen Bild-Port. Der erste (bevorzugte) Port wird für
   * `STREAM_PORT_RETRY_MS` wiederholt versucht, bevor er aufgibt; weitere Ports
   * werden sofort einmal versucht. Gibt bei Erfolg den Socket zurück und öffnet
   * den Nachrichten-Empfang.
   */
  private async bindStreamPort(port: number, isPreferred: boolean): Promise<dgram.Socket | null> {
    const deadline = Date.now() + (isPreferred ? STREAM_PORT_RETRY_MS : 0);
    for (;;) {
      try {
        const sock = await bindUdp(port);
        sock.on("message", (buf, rinfo) => this.onStreamData(buf, rinfo, port));
        this.streamSocks.push(sock);
        this.boundStreamPorts.push(port);
        return sock;
      } catch (err) {
        const msg = (err as Error).message;
        if (Date.now() >= deadline) {
          this.log(`Bild-Port ${port} nicht nutzbar: ${msg}`);
          return null;
        }
        await delay(STREAM_PORT_RETRY_INTERVAL_MS);
      }
    }
  }

  private async openVideo(): Promise<void> {
    try {
      await this.sendOpenVideo();
    } catch (err) {
      // Ältere Firmware kennt die Port-Nutzlast evtl. nicht → ohne versuchen.
      // Hat der Port-Modus schon Bilder geliefert, ist es nur ein Ausfall.
      if (this.openMode !== "port" || this.everReceived) throw err;
      this.log(`OpenVideo mit Port fehlgeschlagen (${(err as Error).message}) – versuche ohne Nutzlast`);
      this.openMode = "plain";
      await this.sendOpenVideo();
    }
  }

  private async sendOpenVideo(): Promise<void> {
    let payload = Buffer.alloc(0);
    let advertised: number | null = null;
    if (this.openMode === "port") {
      // Nur einen Port bewerben, der auch wirklich gebunden ist – sonst schickt
      // die Kamera den Bildstrom ins Leere, während der Befehlskanal läuft.
      advertised = this.boundStreamPorts[0]!;
      payload = Buffer.alloc(2);
      payload.writeUInt16LE(advertised, 0);
    }
    // Wichtig: OpenVideo vom Bild-Socket aus senden, nicht vom Befehls-Socket.
    // Die Kamera schickt den Strom an den Quellport der Anfrage – so landet er
    // garantiert auf dem Socket, auf dem schon auf Chunks gehört wird (wie beim
    // Ein-Socket-Client der Handy-App).
    const streamSock = this.streamSocks[0];
    const res = streamSock
      ? await this.requestOn(streamSock, this.config.cameraVideoPort, MsgType.OpenVideo, payload)
      : await this.request(this.config.cameraVideoPort, MsgType.OpenVideo, payload);
    if (res.errCode !== 0) throw new Error(`OpenVideo (${this.openMode}): Fehlercode ${res.errCode}`);
    this.lastDataAt = Date.now();
    this.log(`OpenVideo gesendet (Modus ${this.openMode})`);
  }

  private checkStall(): void {
    if (!this.connected || this.restartPending || Date.now() - this.lastDataAt < STALL_MS) return;
    if (!this.everReceived && this.openMode === "port") this.openMode = "plain";
    this.error = this.everReceived
      ? "Bildstrom unterbrochen – starte neu"
      : "Keine Bilddaten von der Kamera – versuche anderen Startmodus";
    this.stallError = true;
    this.log(this.error);
    this.lastDataAt = Date.now(); // nicht bei jedem Tick erneut versuchen
    this.restartPending = true;
    this.openVideo()
      .catch((e) => this.log(`OpenVideo fehlgeschlagen: ${(e as Error).message}`))
      .finally(() => (this.restartPending = false));
  }

  /**
   * Ist das Datagramm die Antwort auf eine gerade offene Anfrage? Dann gehört
   * es `requestOnce` und darf nicht als Bildstrom verarbeitet werden. Wichtig:
   * nur echte Nachrichten (gültiger Header + erwarteter Typ) zählen als Antwort
   * – Bild-Chunks vom selben Quellport (10006) müssen durchgelassen werden.
   */
  private isCommandReply(buf: Buffer, rinfo: dgram.RemoteInfo): boolean {
    if (!this.pendingReplyPorts.has(rinfo.port)) return false;
    const msg = decodeMessage(buf);
    return msg !== null;
  }

  private onStreamData(buf: Buffer, rinfo: dgram.RemoteInfo, port: number): void {
    if (rinfo.address !== this.config.cameraIp) return;
    this.lastDataAt = Date.now();
    if (!this.everReceived) {
      this.everReceived = true;
      this.details = { ...this.details, Empfangsport: String(port), Startmodus: this.openMode };
      this.log(`Erste Bilddaten auf Port ${port} (Startmodus ${this.openMode})`);
    }
    if (this.stallError) {
      this.stallError = false;
      this.error = null;
    }

    for (const chunk of parseChunks(buf)) {
      for (const frame of this.assembler.push(chunk)) {
        this.details.Auflösung = `${frame.width}×${frame.height}`;
        this.pushFrame(frame.jpeg);
        this.pushSensor(this.smoother.push(frame.accel, frame.flags));
      }
    }
  }

  /**
   * Anfrage/Antwort auf dem Befehls-Socket. Serialisiert – die Kamera
   * beantwortet eine Anfrage nach der anderen; Antworten werden über
   * Absenderport und Nachrichtentyp zugeordnet.
   */
  private request(port: number, type: number, data?: Buffer, timeoutMs = 1500, attempts = 3): Promise<Message> {
    const run = async (): Promise<Message> => {
      let lastErr: Error = new Error("keine Antwort");
      for (let i = 0; i < attempts; i++) {
        try {
          return await this.requestOnce(port, type, data, timeoutMs);
        } catch (e) {
          lastErr = e as Error;
        }
      }
      throw lastErr;
    };
    const p = this.queue.then(run, run);
    this.queue = p.catch(() => undefined);
    return p;
  }

  private async requestOnce(port: number, type: number, data: Buffer | undefined, timeoutMs: number): Promise<Message> {
    const sock = this.cmdSock;
    if (!sock) return Promise.reject(new Error("nicht verbunden"));
    return this.sendRequestOn(sock, port, type, data, timeoutMs);
  }

  /**
   * Wie `request`, aber über einen bestimmten Socket (z. B. den Bild-Socket für
   * OpenVideo). Serialisiert mit allen anderen Anfragen.
   */
  private requestOn(sock: dgram.Socket, port: number, type: number, data: Buffer, timeoutMs = 1500, attempts = 3): Promise<Message> {
    const run = async (): Promise<Message> => {
      let lastErr: Error = new Error("keine Antwort");
      for (let i = 0; i < attempts; i++) {
        try {
          return await this.sendRequestOn(sock, port, type, data, timeoutMs);
        } catch (e) {
          lastErr = e as Error;
        }
      }
      throw lastErr;
    };
    const p = this.queue.then(run, run);
    this.queue = p.catch(() => undefined);
    return p;
  }

  private sendRequestOn(
    sock: dgram.Socket,
    port: number,
    type: number,
    data: Buffer | undefined,
    timeoutMs: number,
  ): Promise<Message> {
    const packet = encodeMessage(this.msgId++, type, data);
    this.pendingReplyPorts.add(port);
    return new Promise((resolve, reject) => {
      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp || rinfo.port !== port) return;
        const msg = decodeMessage(buf);
        if (!msg || msg.type !== type) return;
        cleanup();
        resolve(msg);
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Zeitüberschreitung (Typ ${type}, Port ${port})`));
      }, timeoutMs);
      const cleanup = () => {
        clearTimeout(timer);
        sock.off("message", onMessage);
        this.pendingReplyPorts.delete(port);
      };
      sock.on("message", onMessage);
      sock.send(packet, port, this.config.cameraIp, (err) => {
        if (err) {
          cleanup();
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
      const sock = dgram.createSocket({ type: "udp4", reuseAddr: false });
      const timer = setTimeout(() => {
        sock.close();
        reject(new Error("probe timeout"));
      }, timeoutMs);

      const onMessage = (buf: Buffer, rinfo: dgram.RemoteInfo) => {
        if (rinfo.address !== this.config.cameraIp || rinfo.port !== port) return;
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

function bindUdp(port: number, reuseAddr = true): Promise<dgram.Socket> {
  return new Promise((resolve, reject) => {
    // `reuseAddr` wie RawDatagramSocket.bind in der Handy-App (Dart-Default true).
    const sock = dgram.createSocket({ type: "udp4", reuseAddr });
    sock.once("error", reject);
    // Wie Dart: ausdrücklich auf allen IPv4-Adressen lauschen (0.0.0.0).
    sock.bind(port, "0.0.0.0", () => {
      sock.off("error", reject);
      sock.on("error", () => undefined); // spätere ICMP-Fehler nicht als Absturz werten
      resolve(sock);
    });
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
