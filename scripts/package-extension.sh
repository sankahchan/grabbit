#!/usr/bin/env bash
# package-extension.sh — build the Chrome Web Store ZIP for GrabbitExtension.
#
# The store package contains runtime files only. The manifest's "key" field is
# stripped so the Web Store assigns its own item ID (the repo manifest keeps
# the key so unpacked development loads keep their stable extension ID).
#
# Usage: ./scripts/package-extension.sh
# Output: dist/grabbit-extension-v<version>.zip
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SRC="GrabbitExtension"
OUT="dist"
VERSION=$(python3 -c "import json; print(json.load(open('$SRC/manifest.json'))['version'])")
ZIP="$ROOT/$OUT/grabbit-extension-v$VERSION.zip"

mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Runtime files only (README/notes/native-messaging are development material).
cp "$SRC/manifest.json" "$STAGE/manifest.json"
cp "$SRC/background.js" "$STAGE/background.js"
cp "$SRC/content.js" "$STAGE/content.js"
cp "$SRC/page-hook.js" "$STAGE/page-hook.js"
cp "$SRC/popup.html" "$STAGE/popup.html"
cp "$SRC/popup.js" "$STAGE/popup.js"
mkdir -p "$STAGE/icons"
cp "$SRC/icons/"*.png "$STAGE/icons/"

# Strip the development "key" field (Web Store assigns the item ID).
python3 - "$STAGE/manifest.json" <<'PYEOF'
import json, sys

path = sys.argv[1]
data = json.load(open(path))
data.pop("key", None)
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PYEOF

# Sanity checks before shipping.
python3 - "$STAGE/manifest.json" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
base = os.path.dirname(path)
manifest = json.load(open(path))
assert manifest["manifest_version"] == 3, "not an MV3 manifest"
assert "key" not in manifest, "development key leaked into the store package"
for name in ("background.js", "content.js", "page-hook.js", "popup.html", "popup.js"):
    assert os.path.exists(os.path.join(base, name)), f"missing {name}"
for icon in manifest["icons"].values():
    assert os.path.exists(os.path.join(base, icon)), f"missing {icon}"
print(f"manifest ok: v{manifest['version']} ({manifest['name']})")
PYEOF

rm -f "$ZIP"
(cd "$STAGE" && zip -q -r -X "$ZIP" .)
echo
echo "packaged -> $ZIP"
unzip -l "$ZIP"
