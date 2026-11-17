#!/bin/bash
# Baut die Dateien für den Store (kulisse.finnegan-berz.com) und den Katalog.
#
#   store/make-store.sh [ausgabe]     (Standard: dist/store)
#
# Ausgabe (landet in der Pipeline als Assets im Release "latest" bzw. im Tag-Release):
#   wallpaper-<id>.wallpapertheme   Doppelklick installiert den Hintergrund in Kulisse (inkl. Ordner)
#   wallpaper-<id>.zip              Projektordner für Wallpaper Engine (Windows) oder "Importieren …"
#   pointer-<id>.pointertheme       Zeiger-Design, Doppelklick importiert es
# Dazu wird store/catalog.json aus store/meta.json neu geschrieben (wird eingecheckt; der Store lädt ihn
# über raw.githubusercontent.com). Mit --check bricht das Script ab, wenn der eingecheckte Katalog veraltet ist.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK=0; [[ "${1:-}" == "--check" ]] && { CHECK=1; shift; }
OUT="${1:-dist/store}"
rm -rf "$OUT"; mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 - "$OUT" "$TMP" "$CHECK" <<'PY'
import json, os, shutil, subprocess, sys

out, tmp, check = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
meta = json.load(open("store/meta.json"))

def ditto(*args):
    subprocess.run(["ditto", "-c", "-k", "--norsrc", *args], check=True)

def fail(msg):
    sys.exit(f"make-store: {msg}")

# ---------- Live-Hintergründe ----------
found = sorted(d for d in os.listdir("wallpapers") if os.path.isfile(f"wallpapers/{d}/project.json"))
listed = [w["id"] for w in meta["wallpapers"]]
for d in found:
    if d not in listed: fail(f"wallpapers/{d} fehlt in store/meta.json")
wallpapers = []
for w in meta["wallpapers"]:
    wid = w["id"]
    if wid not in found: fail(f"store/meta.json nennt {wid}, aber wallpapers/{wid}/project.json fehlt")
    project = json.load(open(f"wallpapers/{wid}/project.json"))
    preview = project.get("preview") or fail(f"wallpapers/{wid}: project.json ohne preview")
    if not os.path.isfile(f"wallpapers/{wid}/{preview}"): fail(f"wallpapers/{wid}/{preview} fehlt")

    # Für Wallpaper Engine / "Importieren …": der Ordner selbst
    ditto("--keepParent", f"wallpapers/{wid}", f"{out}/wallpaper-{wid}.zip")
    # Für Kulisse: wallpaper.json + files/ (Format siehe src/wallpaper.swift)
    pkg = f"{tmp}/{wid}"
    os.makedirs(pkg)
    json.dump({"format": 1, "name": w["title"], "wallpaper": f"builtin/{wid}",
               "title": project.get("title", w["title"]), "values": {}},
              open(f"{pkg}/wallpaper.json", "w"), ensure_ascii=False, indent=2)
    shutil.copytree(f"wallpapers/{wid}", f"{pkg}/files")
    ditto(pkg, f"{out}/wallpaper-{wid}.wallpapertheme")

    item = {"id": wid, "title": w["title"], "description": w["description"],
            "screens": w.get("screens", 1), "preview": f"wallpapers/{wid}/{preview}",
            "files": {"kulisse": f"wallpaper-{wid}.wallpapertheme", "engine": f"wallpaper-{wid}.zip"}}
    if "credit" in w: item["credit"] = w["credit"]
    wallpapers.append(item)

# ---------- Zeiger-Designs ----------
found = sorted(f for f in os.listdir("themes") if f.endswith(".pointertheme"))
listed = [p["file"] for p in meta["pointers"]]
for f in found:
    if f not in listed: fail(f"themes/{f} fehlt in store/meta.json")
pointers = []
for p in meta["pointers"]:
    if p["file"] not in found: fail(f"store/meta.json nennt {p['file']}, aber themes/{p['file']} fehlt")
    preview = f"store/previews/pointer-{p['id']}.png"
    if not os.path.isfile(preview): fail(f"{preview} fehlt (Vorschau des Designs, transparentes PNG)")
    shutil.copy(f"themes/{p['file']}", f"{out}/pointer-{p['id']}.pointertheme")
    item = {"id": p["id"], "title": p["title"], "description": p["description"],
            "preview": preview, "file": f"pointer-{p['id']}.pointertheme"}
    if "credit" in p: item["credit"] = p["credit"]
    pointers.append(item)

catalog = {
    "format": 1,
    "repo": "finnbe/Kulisse",
    "release": "latest",
    "app": {"file": "Kulisse-macOS.zip"},
    "wallpapers": wallpapers,
    "pointers": pointers,
}
text = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
if check:
    if not os.path.isfile("store/catalog.json") or open("store/catalog.json").read() != text:
        fail("store/catalog.json ist veraltet – store/make-store.sh ausführen und einchecken")
else:
    open("store/catalog.json", "w").write(text)
shutil.copy("store/catalog.json", f"{out}/catalog.json")
print(f"make-store: {len(wallpapers)} Hintergründe, {len(pointers)} Designs -> {out}")
PY
