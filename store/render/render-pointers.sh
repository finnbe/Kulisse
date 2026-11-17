#!/bin/bash
# Vorschauen der eingebauten Zeiger-Designs für den Store (store/previews/builtin-<id>.webp + -still.png).
# Rendert offscreen mit dem echten Design-Code aus src/ – kein Bildschirm, keine echte Maus nötig.
#
#   store/render/render-pointers.sh [design …]       (ohne Angabe: alle)
# Braucht: Xcode Command Line Tools, ffmpeg und img2webp (brew install ffmpeg webp).
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Die Designs brauchen ein paar Typen aus src/main.swift (dort mit der App verwoben) – herausziehen statt kopieren
{
  echo "import Cocoa"
  grep -m1 "^let DRAW_WIDTH" src/main.swift
  # Theme, Holder, findResource, HandSprite, loadSprite, prepare – alles vor der Zeichenfläche
  awk '/^enum Theme: String/{p=1} /^\/\/ ---------- Zeichenfläche/{exit} p{print}' src/main.swift
} > "$WORK/shared.swift"

swiftc -O -o "$WORK/render" store/render/main.swift "$WORK/shared.swift" \
  src/halloween.swift src/addmore.swift src/zug.swift src/fuesse.swift src/ente.swift \
  src/skelett.swift src/ufo.swift src/wueste.swift src/peitsche.swift \
  -framework Cocoa -framework AVFoundation -framework Metal
"$WORK/render" "$WORK/frames" "$@"

mkdir -p store/previews
for dir in "$WORK"/frames/*/; do
  id="$(basename "$dir")"
  # CARenderer liefert die Zeilen von unten nach oben (vflip). Animiert: 450 px hoch (halbe Renderauflösung reicht für die Kachel), Endlosschleife, 25 fps
  mkdir -p "$WORK/small/$id"
  ffmpeg -loglevel error -y -i "$dir/%04d.png" -vf "vflip,scale=-2:450:flags=lanczos" "$WORK/small/$id/%04d.png"
  img2webp -loop 0 -lossy -q 70 -m 6 -d 40 "$WORK"/small/"$id"/*.png -o "store/previews/builtin-$id.webp" >/dev/null
  # Standbild für "Bewegung reduzieren" (Bild aus der Mitte der Schleife)
  ffmpeg -loglevel error -y -i "$dir/0075.png" -vf "vflip,scale=-2:450:flags=lanczos" "store/previews/builtin-$id-still.png"
  echo "$id: $(du -h "store/previews/builtin-$id.webp" | cut -f1)"
done

# Stab-Designs zeichnet die App direkt aus Handbildern – dafür ein Standbild aus dem Bild selbst
if [ $# -eq 0 ]; then
  for pair in zeigestock:zeigestock-hand waschbaer:waschbaer-hand halter:waschbaer-halter; do
    id="${pair%%:*}"; img="${pair#*:}.png"
    sips -s format png --resampleHeight 360 "$img" --out "store/previews/builtin-$id-still.png" >/dev/null
    echo "$id: Standbild"
  done
fi
