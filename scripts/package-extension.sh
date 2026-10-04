#!/usr/bin/env bash
# package-extension.sh — build the Chrome Web Store ZIP for GrabbitExtension.
#
# The store package contains runtime files only and is built with YouTube
# capture disabled (Web Store policy; see STORE.md). Pass --full to build the
# GitHub flavor instead, which keeps every site enabled.
#
# The manifest's "key" field is stripped so the Web Store assigns its own
# item ID (the repo manifest keeps the key so unpacked development loads keep
# their stable extension ID).
#
# Usage: ./scripts/package-extension.sh [--full]
# Output: dist/grabbit-extension-v<version>.zip        (store)
#         dist/grabbit-extension-v<version>-full.zip   (--full)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

FULL_BUILD=0
if [[ "${1:-}" == "--full" ]]; then
  FULL_BUILD=1
fi

SRC="GrabbitExtension"
OUT="dist"
VERSION=$(python3 -c "import json; print(json.load(open('$SRC/manifest.json'))['version'])")
if [[ $FULL_BUILD -eq 1 ]]; then
  ZIP="$ROOT/$OUT/grabbit-extension-v$VERSION-full.zip"
else
  ZIP="$ROOT/$OUT/grabbit-extension-v$VERSION.zip"
fi

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

# The full (GitHub) build ships a user-facing install guide next to the
# extension files; the store package stays runtime-only.
if [[ $FULL_BUILD -eq 1 ]] && [[ -f "$SRC/INSTALL.txt" ]]; then
  cp "$SRC/INSTALL.txt" "$STAGE/INSTALL.txt"
fi

# The store assigns its own item ID, so the development "key" field must be
# stripped there. The full (GitHub) build keeps the key: unpacked loads then
# get the stable development ID that the app's native-host manifest allows.
if [[ $FULL_BUILD -eq 0 ]]; then
  python3 - "$STAGE/manifest.json" <<'PYEOF'
import json, sys

path = sys.argv[1]
data = json.load(open(path))
data.pop("key", None)
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PYEOF
fi

# Flip the compliance flag in the store flavor. The flag lives in both the
# service worker and the content script.
WANT="false"
if [[ $FULL_BUILD -eq 0 ]]; then
  WANT="true"
fi
for f in "$STAGE/background.js" "$STAGE/content.js"; do
  python3 - "$f" "$WANT" <<'PYEOF'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
want = sys.argv[2]
src = path.read_text()
needle = "const GRABBIT_STORE_BUILD = false;"
replacement = f"const GRABBIT_STORE_BUILD = {want};"
assert needle in src, f"store flag missing in {path.name}"
path.write_text(src.replace(needle, replacement))
PYEOF
done

# Sanity checks before shipping.
python3 - "$STAGE/manifest.json" "$FULL_BUILD" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
full = sys.argv[2] == "1"
base = os.path.dirname(path)
manifest = json.load(open(path))
assert manifest["manifest_version"] == 3, "not an MV3 manifest"
if full:
    assert "key" in manifest, "full build must keep the stable development key"
else:
    assert "key" not in manifest, "development key leaked into the store package"
for name in ("background.js", "content.js", "page-hook.js", "popup.html", "popup.js"):
    assert os.path.exists(os.path.join(base, name)), f"missing {name}"
for icon in manifest["icons"].values():
    assert os.path.exists(os.path.join(base, icon)), f"missing {icon}"
print(f"manifest ok: v{manifest['version']} ({manifest['name']})")
PYEOF
grep -q "const GRABBIT_STORE_BUILD = $WANT;" "$STAGE/background.js"
grep -q "const GRABBIT_STORE_BUILD = $WANT;" "$STAGE/content.js"
if [[ $FULL_BUILD -eq 1 ]]; then
  echo "flavor: full — every site enabled"
else
  echo "flavor: store — YouTube capture disabled"
fi

rm -f "$ZIP"
(cd "$STAGE" && zip -q -r -X "$ZIP" .)
echo
echo "packaged -> $ZIP"
unzip -l "$ZIP"
