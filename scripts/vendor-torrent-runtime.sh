#!/bin/bash
# vendor-torrent-runtime.sh — fetch the aria2-next torrent daemon binary.
#
# Downloads the pinned aria2-next macOS arm64 release from
# AnInsomniacy/aria2-next (actively maintained fork; prebuilt binaries with
# SHA-256 checksums per release) into Grabbit/Resources/bin/aria2-next.
# The checksum file is verified against the pinned hash below, so a silently
# replaced upstream asset fails the build instead of shipping.
#
# Binaries are NOT committed to git (see .gitignore); release.yml runs this
# script at build time. Versions are pinned below for reproducible builds —
# bump on a cadence (monthly, or when the fork publishes fixes).
#
# License note: aria2-next is GPL-2.0-or-later. The binary stays a separate
# program driven over JSON-RPC; Grabbit's own source remains MIT. Keep this
# script next to the release manifest so the attribution/source-offer
# obligation is visible (see DEPENDENCIES.md).
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Pinned version ----------------------------------------------------------
ARIA2_NEXT_VERSION="2.8.2"
# SHA-256 of aria2-next-2.8.2-macos-arm64, from the release's checksums file.
ARIA2_NEXT_SHA256="32abfca1ebeeff020aa47c30e3680c86162ab49703dc4924a0510557b830a69f"

OUT="Grabbit/Resources/bin"
LIB="Grabbit/Resources/lib"
mkdir -p "$OUT" "$LIB"

ASSET="aria2-next-${ARIA2_NEXT_VERSION}-macos-arm64"
BASE_URL="https://github.com/AnInsomniacy/aria2-next/releases/download/v${ARIA2_NEXT_VERSION}"

relocate_dylibs() {
    # Same approach as vendor-media-runtime.sh: copy every non-system dylib
    # the binary links against into lib/ and rewrite its load path to
    # @executable_path/../lib/<name> (binaries live in Resources/bin).
    local bin="$1" libdir="$2"
    local dylibs
    dylibs=$(otool -L "$bin" | awk '{print $1}' | grep -E '/(opt/homebrew|usr/local)/' || true)
    for dylib in $dylibs; do
        local name
        name=$(basename "$dylib")
        if [[ ! -f "$libdir/$name" ]]; then
            echo "  vendoring dylib $name"
            cp -f "$dylib" "$libdir/$name"
            chmod 644 "$libdir/$name"
            relocate_dylibs "$libdir/$name" "$libdir"
        fi
        install_name_tool -change "$dylib" "@executable_path/../lib/$name" "$bin"
    done
}

sign() {
    # Ad-hoc sign (release signing happens later in the pipeline).
    codesign --force --sign - "$1" 2>/dev/null || true
}

echo "downloading $ASSET"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL -o "$tmp/$ASSET" "${BASE_URL}/${ASSET}"
curl -fL -o "$tmp/checksums.sha256" "${BASE_URL}/aria2-next-${ARIA2_NEXT_VERSION}-checksums.sha256"

# Verify the checksums file itself pins the expected hash (catches a
# silently replaced asset), then verify the download against the file.
expected=$(grep "  ${ASSET}\$" "$tmp/checksums.sha256" | awk '{print $1}')
if [[ "$expected" != "$ARIA2_NEXT_SHA256" ]]; then
    echo "ERROR: upstream checksum for $ASSET changed:"
    echo "  pinned:   $ARIA2_NEXT_SHA256"
    echo "  upstream: $expected"
    echo "Refusing to vendor — review the release, then bump the pin."
    exit 1
fi
(cd "$tmp" && shasum -a 256 -c <(echo "$ARIA2_NEXT_SHA256  $ASSET"))

cp -f "$tmp/$ASSET" "$OUT/aria2-next"
chmod +x "$OUT/aria2-next"
relocate_dylibs "$OUT/aria2-next" "$LIB"
sign "$OUT/aria2-next"

for lib in "$LIB"/*.dylib; do
    [[ -e "$lib" ]] || continue
    sign "$lib"
done

echo "--- vendored ---"
ls -la "$OUT/aria2-next"
"$OUT/aria2-next" --version | head -3
