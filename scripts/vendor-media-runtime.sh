#!/bin/bash
# vendor-media-runtime.sh — fetch + relocate the media helper binaries.
#
# Downloads yt-dlp (universal2), a static arm64 ffmpeg/ffprobe, and deno
# (aarch64) into Grabbit/Resources/bin/. When VENDOR_FROM_HOMEBREW=1, copies
# from the local Homebrew prefix instead and relocates non-system dylibs
# into Grabbit/Resources/lib via install_name_tool (Harbor's
# vendor-media-runtime.sh idea), then ad-hoc re-signs everything.
#
# Binaries are NOT committed to git (see .gitignore); release.yml runs this
# script at build time. Versions are pinned below for reproducible builds —
# bump on a cadence (monthly, or when a site breaks).
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Pinned versions ---------------------------------------------------------
YTDLP_VERSION="2026.08.19"
FFMPEG_STATIC_TAG="b6.1.1"  # eugeneware/ffmpeg-static (darwin-arm64)
DENO_VERSION="2.4.5"

OUT="Grabbit/Resources/bin"
LIB="Grabbit/Resources/lib"
mkdir -p "$OUT" "$LIB"

# --- Helpers -----------------------------------------------------------------
relocate_dylibs() {
    # $1 = binary, $2 = lib dir. Copies every non-system dylib the binary
    # links against into lib/ and rewrites its load path to
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
            # Recurse: the dylib may have its own Homebrew deps.
            relocate_dylibs "$libdir/$name" "$libdir"
        fi
        install_name_tool -change "$dylib" "@executable_path/../lib/$name" "$bin"
    done
}

sign() {
    # Ad-hoc sign (release signing happens later in the pipeline).
    codesign --force --sign - "$1" 2>/dev/null || true
}

# --- yt-dlp (universal2, no dylibs) -------------------------------------------
if [[ "${VENDOR_FROM_HOMEBREW:-0}" == "1" && -x /opt/homebrew/bin/yt-dlp ]]; then
    echo "vendoring yt-dlp from Homebrew"
    cp -f /opt/homebrew/bin/yt-dlp "$OUT/yt-dlp"
else
    echo "downloading yt-dlp_macos $YTDLP_VERSION"
    curl -fL -o "$OUT/yt-dlp" \
        "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"
fi
chmod +x "$OUT/yt-dlp"
sign "$OUT/yt-dlp"

# --- deno (aarch64, needed for YouTube JS challenges) -------------------------
if [[ "${VENDOR_FROM_HOMEBREW:-0}" == "1" && -x /opt/homebrew/bin/deno ]]; then
    echo "vendoring deno from Homebrew"
    cp -f /opt/homebrew/bin/deno "$OUT/deno"
    relocate_dylibs "$OUT/deno" "$LIB"
else
    echo "downloading deno $DENO_VERSION (aarch64-apple-darwin)"
    tmp=$(mktemp -d)
    curl -fL -o "$tmp/deno.zip" \
        "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-aarch64-apple-darwin.zip"
    unzip -o -q "$tmp/deno.zip" -d "$tmp"
    cp -f "$tmp/deno" "$OUT/deno"
    rm -rf "$tmp"
fi
chmod +x "$OUT/deno"
sign "$OUT/deno"

# --- ffmpeg + ffprobe (static arm64; no dylibs to relocate) --------------------
# evermeet.cx only publishes x86_64 builds. Downloading it here shipped an
# x86_64 ffmpeg inside an arm64-only app: on Apple Silicon without Rosetta
# every post-processing step failed with "ffmpeg not found". ffmpeg-static
# publishes real arm64 binaries that link only system frameworks.
FFMPEG_STATIC_BASE="https://github.com/eugeneware/ffmpeg-static/releases/download/${FFMPEG_STATIC_TAG}"
if [[ "${VENDOR_FROM_HOMEBREW:-0}" == "1" && -x /opt/homebrew/bin/ffmpeg ]]; then
    echo "vendoring ffmpeg/ffprobe from Homebrew"
    cp -f /opt/homebrew/bin/ffmpeg "$OUT/ffmpeg"
    cp -f /opt/homebrew/bin/ffprobe "$OUT/ffprobe" 2>/dev/null || true
    relocate_dylibs "$OUT/ffmpeg" "$LIB"
    [[ -x "$OUT/ffprobe" ]] && relocate_dylibs "$OUT/ffprobe" "$LIB" || true
else
    echo "downloading static ffmpeg/ffprobe $FFMPEG_STATIC_TAG (arm64)"
    curl -fL -o "$OUT/ffmpeg" "${FFMPEG_STATIC_BASE}/ffmpeg-darwin-arm64"
    curl -fL -o "$OUT/ffprobe" "${FFMPEG_STATIC_BASE}/ffprobe-darwin-arm64"
fi
chmod +x "$OUT/ffmpeg"
[[ -f "$OUT/ffprobe" ]] && chmod +x "$OUT/ffprobe" || true
sign "$OUT/ffmpeg"
[[ -f "$OUT/ffprobe" ]] && sign "$OUT/ffprobe" || true

# --- Architecture guard --------------------------------------------------------
# A binary with the wrong CPU type still passes `chmod +x` and looks fine to the
# resolver, but fails at exec ("bad CPU type"). Fail the build instead of
# shipping a helper that only works when Rosetta happens to be installed.
check_binary() {
    local bin="$1"
    if [[ ! -f "$bin" ]]; then
        echo "ERROR: $bin was not vendored" >&2
        exit 1
    fi
    local archs
    archs=$(lipo -archs "$bin" 2>/dev/null || echo "unknown")
    if [[ "$archs" != *arm64* ]]; then
        echo "ERROR: $bin has arch '$archs', expected arm64" >&2
        exit 1
    fi
}
check_binary "$OUT/yt-dlp"
check_binary "$OUT/deno"
check_binary "$OUT/ffmpeg"
check_binary "$OUT/ffprobe"

# Running the helpers catches missing dylibs too, but only on an arm64 host.
if [[ "$(uname -m)" == "arm64" ]]; then
    for helper in ffmpeg ffprobe; do
        if ! "$OUT/$helper" -version >/dev/null 2>&1; then
            echo "ERROR: $OUT/$helper does not run on this machine" >&2
            exit 1
        fi
    done
fi

# --- Sign relocated dylibs -----------------------------------------------------
for lib in "$LIB"/*.dylib; do
    [[ -e "$lib" ]] || continue
    sign "$lib"
done

echo "--- vendored ---"
ls -la "$OUT"
[[ -n "$(ls -A "$LIB" 2>/dev/null)" ]] && ls -la "$LIB" || echo "(no relocated dylibs)"
