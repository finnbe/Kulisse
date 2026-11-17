#!/bin/bash
# Baut "Kulisse.app" neu (braucht die Xcode Command Line Tools: xcode-select --install)
set -e
cd "$(dirname "$0")"
APP="../Kulisse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Architekturen: Standard nur die des eigenen Macs (schnell); UNIVERSAL=1 baut Apple Silicon + Intel in eine Datei (Pipeline)
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
TMP="$(mktemp -d)"
# compile <ausgabe> <swiftc-Argumente…>: je Architektur bauen, dann mit lipo zusammenfügen
compile() {
  local out="$1"; shift
  local parts=()
  for a in $ARCHS; do
    swiftc -O -target "$a-apple-macos12.0" "$@" -o "$TMP/$(basename "$out").$a"
    parts+=("$TMP/$(basename "$out").$a")
  done
  lipo -create "${parts[@]}" -output "$out"
}
compile "$APP/Contents/MacOS/Kulisse" main.swift halloween.swift addmore.swift zug.swift fuesse.swift ente.swift themes.swift skelett.swift ufo.swift wueste.swift peitsche.swift yuzu.swift wallpaper.swift wallpaper_ui.swift wallpaper_audio.swift wachhalten.swift -framework Cocoa -framework Carbon -framework AVFoundation -framework WebKit -framework IOKit -framework CoreAudio -framework AudioToolbox -framework Accelerate
cp platzhalter-hand.png "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"          # App-Symbol (Vorhang mit Mondnacht, lokal mit Z-Image-Turbo erzeugt)
# Live-Hintergründe (Ordner wallpapers/ neben src/)
[ -d ../wallpapers ] && ditto --norsrc ../wallpapers "$APP/Contents/Resources/wallpapers"
for f in ../*-hand.png ../*-halter.png ../*-halter.json ../*.mp3; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kulisse</string>
  <key>CFBundleDisplayName</key><string>Kulisse</string>
  <key>CFBundleIdentifier</key><string>local.kulisse.app</string>
  <key>CFBundleExecutable</key><string>Kulisse</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Pointer-Design</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.kulisse.pointertheme</string></array>
  </dict><dict>
    <key>CFBundleTypeName</key><string>Live-Hintergrund</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.kulisse.wallpapertheme</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.kulisse.pointertheme</string>
    <key>UTTypeDescription</key><string>Pointer-Design</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>pointertheme</string></array>
    </dict>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>local.kulisse.wallpapertheme</string>
    <key>UTTypeDescription</key><string>Live-Hintergrund</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>wallpapertheme</string></array>
    </dict>
  </dict></array>
  <key>NSAudioCaptureUsageDescription</key><string>Der Live-Hintergrund hört den Systemton mit, damit er zur Musik tanzen kann. Es wird nichts aufgenommen oder gespeichert.</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Bildschirmschoner (eigenes Bündel, liegt in der App und wird von dort nach ~/Library/Screen Savers kopiert)
SAVER="$APP/Contents/Resources/Kulisse.saver"
mkdir -p "$SAVER/Contents/MacOS"
compile "$SAVER/Contents/MacOS/KulisseSaver" -emit-library -module-name KulisseSaver saver.swift -framework Cocoa -framework ScreenSaver -framework WebKit
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kulisse</string>
  <key>CFBundleDisplayName</key><string>Kulisse</string>
  <key>CFBundleIdentifier</key><string>local.kulisse.saver</string>
  <key>CFBundleExecutable</key><string>KulisseSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSPrincipalClass</key><string>KulisseSaverView</string>
</dict></plist>
PLIST
codesign --force -s - "$SAVER"
codesign --force --deep -s - "$APP"
rm -rf "$TMP"
echo "Fertig: $APP ($ARCHS)"
