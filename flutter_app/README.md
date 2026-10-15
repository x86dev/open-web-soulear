# OpenEarcam – Handy-App (Flutter)

Native App für Android (und iOS) – spricht **direkt** per UDP mit der Kamera,
ohne Backend, ohne Cloud. Gleicher Funktionsumfang wie die Web-App in
[../app](../app/README.md): Livebild, Foto, LED an/aus, Akku, Lagesensor mit
Bildstabilisierung, Galerie, Geräteinfo.

<img src="../docs/screenshot-android.png" alt="OpenEarcam als Android-App mit der echten Kamera: stabilisiertes Livebild, Bedienknöpfe und Tab Lage mit Sensorwerten" width="300">

| Teil | Status |
|---|---|
| Protokoll in Dart (`lib/src/protocol.dart`) | fertig, Unit-Tests |
| Soulear-Treiber (`lib/src/soulear_client.dart`) | fertig, gegen die simulierte Kamera getestet |
| AIR-Look-Treiber (`lib/src/airlook_client.dart`) | Livebild, Akku in % und LED an/aus; Protokoll aus `unofficial-airlook-web`, Unit-Tests |
| Auto-Treiber (`lib/src/auto_client.dart`) | probiert Soulear → AIR-Look; Standard |
| Oberfläche Handy/Tablet, hell/dunkel | fertig, Layout-Tests ohne Überläufe |
| Android-Build | APK baut (Release arm64: ~18 MB) |
| Test mit echter Kamera | **läuft** – Nothing Phone (2a), Android 16, mit Kamera `BK7231U-XRH-FBPRO`: Livebild, LED, Stabilisierung, Sensorwerte |
| iOS | Code und Rechte vorbereitet, Build braucht Xcode |

## Installieren (Android)

Voraussetzung: Flutter SDK (getestet mit 3.47) und Android SDK; Handy mit
aktiviertem USB-Debugging per USB verbunden.

```bash
cd flutter_app
flutter build apk --release --split-per-abi --target-platform android-arm64
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Oder mit angeschlossenem Handy direkt: `flutter run --release`.

Die Release-APK ist mit dem lokalen Debug-Schlüssel signiert – für das eigene
Handy ausreichend, nicht für den Play Store.

## Benutzen

1. Kamera einschalten, **Handy mit dem WLAN der Kamera verbinden**
   (`Soulear-…`). Android meldet „kein Internet“ – verbunden bleiben.
2. App öffnen – sie verbindet sich automatisch (Standard: Kamera-Typ „auto“,
   IP `192.168.1.1`). Im Tab **Gerät** lässt sich der Kameratyp
   (`auto`/`soulear`/`airlook`) und die IP ändern.
3. Fotos landen in der App **und** in der Galerie (Album „OpenEarcam“).

**Warum die App sich ans WLAN bindet:** Weil das Kamera-WLAN kein Internet
hat, schickt Android Verbindungen sonst über die mobilen Daten – dann ist die
Kamera nicht erreichbar. `MainActivity.kt` bindet die App deshalb vor dem
Verbinden per `bindProcessToNetwork` an das WLAN (so macht es auch die
Original-App).

## Entwickeln ohne Kamera

```bash
flutter test                                  # Protokoll- und Layout-Tests
(cd ../app && npm run fake-camera)            # simulierte Soulear-Kamera (Terminal 1)
dart run tool/probe.dart soulear 127.0.0.1 5  # Dart-Client dagegen testen (Terminal 2)
dart run tool/probe.dart auto                 # … oder echte Kamera, Treiber raten
dart run tool/probe.dart                      # Standard: auto, 192.168.1.1
```

`tool/probe.dart` verbindet, zählt Bilder, zeigt Sensorwerte und prüft die
LED – dasselbe, was die App tut, nur ohne Oberfläche.

## Aufbau

```
lib/
├── main.dart                 – App, Theme (hell/dunkel nach System)
├── src/
│   ├── protocol.dart         – Suear-Protokoll: Nachrichten, Chunks, Frame-Assembler (reines Dart)
│   ├── airlook_protocol.dart – AIR-Look-Protokoll: Discovery/Status, Videopakete, Assembler
│   ├── camera.dart           – gemeinsame Treiber-Schnittstelle + Status/Capabilities
│   ├── soulear_client.dart   – Soulear/Suear-Treiber (dart:io)
│   ├── airlook_client.dart   – AIR-Look-Treiber (dart:io)
│   ├── auto_client.dart      – Auto-Treiber: probiert soulear → airlook (Standard)
│   └── app_controller.dart   – Zustand, Einstellungen, Fotos, WLAN-Bindung
└── ui/
    ├── home_page.dart        – Layout (breit: Seitenleiste; Handy: untereinander), Bedienleiste
    ├── live_view.dart        – Livebild, Stabilisierung
    ├── sensor_tab.dart       – Lage, Rohwerte, Einstellungen Stabilisierung
    ├── photos_tab.dart       – Galerie, Vollbild mit Zoom
    └── device_tab.dart       – Geräteinfo, Kamera-IP
android/app/src/main/kotlin/…/MainActivity.kt – WLAN-Bindung
test/                         – protocol_test.dart, layout_test.dart
tool/probe.dart               – Kommandozeilen-Test des Clients
tool/make_icon.py             – zeichnet das App-Icon (Stift, flach) → assets/icon/
assets/icon/                  – Icon-Quellen; `dart run flutter_launcher_icons` erzeugt alle Größen
```

Lizenz: GPL-2.0, siehe [../LICENSE](../LICENSE).
