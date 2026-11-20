# Kulisse

<img src="src/AppIcon.png" width="128" alt="Kulisse-Symbol">

Menüleisten-App für macOS: **Zeiger-Designs für Präsentationen** (Waschbär, Laserpointer, Ente mit Küken, UFO …)
und **Live-Hintergründe** für den Schreibtisch im Wallpaper-Engine-Format (Koi-Teich, Yuzu Onsen, Yuzu Onsen Panorama und Himmelsinsel über bis zu 3 Bildschirme), mit
Musikreaktion, Sperrbildschirm-Standbild und eigenem Bildschirmschoner.

## Herunterladen

Unter [Releases](../../releases) liegt `Kulisse-macOS.zip` (Apple Silicon + Intel, ab macOS 12; Musikreaktion ab 14.2).
„Neuester Stand“ wird bei jedem Push automatisch gebaut, Versionen entstehen aus Tags (`v1.0.0`).

Die App ist nur ad hoc signiert, nicht von Apple notarisiert. Beim ersten Start: Rechtsklick auf `Kulisse.app` →
**Öffnen**, oder Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“.

## Hintergründe und Designs einzeln

Auf [kulisse.finnegan-berz.com](https://kulisse.finnegan-berz.com) gibt es jeden Live-Hintergrund und jedes Zeiger-Design
einzeln: `.wallpapertheme` bzw. `.pointertheme` (Doppelklick importiert in Kulisse) und die Hintergründe zusätzlich als
Projektordner für Wallpaper Engine. Die Dateien baut `store/make-store.sh` bei jedem Push ins Release „Neuester Stand“.

Neuer Hintergrund oder neues Design: Eintrag mit deutschem Text in `store/meta.json` (bei Designs zusätzlich eine Vorschau
unter `store/previews/`), dann `store/make-store.sh` ausführen und `store/catalog.json` mit einchecken – die Pipeline
prüft, dass der Katalog aktuell ist.

Die eingebauten Zeiger (Ente, UFO, Zug …) zeigt der Store als animierte Vorschau. Die Bilder rendert
`store/render/render-pointers.sh` offscreen mit dem echten Design-Code aus `src/` (simulierte Mausbahn und Klicks,
kein Bildschirm nötig) – nach Änderungen an einem Design neu ausführen und `store/make-store.sh` danach.

## Selbst bauen

Braucht nur die Xcode Command Line Tools (`xcode-select --install`):

```bash
cd src && ./build.sh            # baut ../Kulisse.app für den eigenen Mac
UNIVERSAL=1 ./build.sh          # Apple Silicon + Intel (braucht volles Xcode)
```

Alles Weitere (Designs, Hintergründe, Einstellungen, Tastenkürzel) steht in [LIESMICH.txt](LIESMICH.txt).
