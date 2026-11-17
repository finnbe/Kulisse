# Kulisse

<img src="src/AppIcon.png" width="128" alt="Kulisse-Symbol">

Menüleisten-App für macOS: **Zeiger-Designs für Präsentationen** (Waschbär, Laserpointer, Ente mit Küken, UFO …)
und **Live-Hintergründe** für den Schreibtisch im Wallpaper-Engine-Format (Koi-Teich, Yuzu Onsen, Yuzu Onsen Panorama über bis zu 3 Bildschirme), mit
Musikreaktion, Sperrbildschirm-Standbild und eigenem Bildschirmschoner.

## Herunterladen

Unter [Releases](../../releases) liegt `Kulisse-macOS.zip` (Apple Silicon + Intel, ab macOS 12; Musikreaktion ab 14.2).
„Neuester Stand“ wird bei jedem Push automatisch gebaut, Versionen entstehen aus Tags (`v1.0.0`).

Die App ist nur ad hoc signiert, nicht von Apple notarisiert. Beim ersten Start: Rechtsklick auf `Kulisse.app` →
**Öffnen**, oder Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“.

## Selbst bauen

Braucht nur die Xcode Command Line Tools (`xcode-select --install`):

```bash
cd src && ./build.sh            # baut ../Kulisse.app für den eigenen Mac
UNIVERSAL=1 ./build.sh          # Apple Silicon + Intel (braucht volles Xcode)
```

Alles Weitere (Designs, Hintergründe, Einstellungen, Tastenkürzel) steht in [LIESMICH.txt](LIESMICH.txt).
