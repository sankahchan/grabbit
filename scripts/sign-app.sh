#!/bin/bash
# Sign a built Grabbit.app with a Developer ID Application identity.
#
# Usage:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)" \
#     ./scripts/sign-app.sh /path/to/Grabbit.app
#
# Set CODESIGN_KEYCHAIN when the identity lives in a temporary keychain (the
# release workflow does this after importing the certificate secret).
#
# Signing order matters: nested helpers, dylibs, frameworks and XPC services
# must be signed before the outer app. `--deep` on the app alone is not enough
# to make Gatekeeper/Sparkle happy, and it can hide a missing nested signature.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "usage: $0 /path/to/Grabbit.app" >&2
    exit 2
fi

IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
if [[ -z "$IDENTITY" ]]; then
    echo "DEVELOPER_ID_APPLICATION is required (for example, 'Developer ID Application: Name (TEAMID)')." >&2
    exit 2
fi

KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
if [[ -n "$KEYCHAIN" ]]; then
    CODESIGN_ARGS+=(--keychain "$KEYCHAIN")
fi

sign_file() {
    local target="$1"
    [[ -f "$target" ]] || return 0
    # Only Mach-O files need a code signature. Scripts and data files in
    # Resources are covered by the app seal.
    if file -b "$target" | grep -q "Mach-O"; then
        codesign "${CODESIGN_ARGS[@]}" "$target"
    fi
}

sign_bundle() {
    local target="$1"
    [[ -d "$target" ]] || return 0
    # Sign the nested code inside Sparkle's framework/app/XPC bundles first.
    codesign "${CODESIGN_ARGS[@]}" --deep "$target"
}

echo "Signing $APP"
echo "Identity: $IDENTITY"
if [[ -n "$KEYCHAIN" ]]; then
    echo "Keychain: $KEYCHAIN"
fi

# Vendored runtimes: yt-dlp, ffmpeg, ffprobe, deno, aria2-next, and the
# Telegram helper. Each is a separate executable spawned by Grabbit, so each
# needs its own Developer ID signature with Hardened Runtime.
if [[ -d "$APP/Contents/Resources/bin" ]]; then
    while IFS= read -r -d '' binary; do
        sign_file "$binary"
    done < <(find "$APP/Contents/Resources/bin" -type f -print0)
fi

# Vendored dylibs (for example the media runtime's shared libraries).
if [[ -d "$APP/Contents/Resources/lib" ]]; then
    while IFS= read -r -d '' library; do
        sign_file "$library"
    done < <(find "$APP/Contents/Resources/lib" -type f -print0)
fi

# Sparkle.framework, its Updater.app/XPC services, and any other embedded
# frameworks. Deepest bundles first so the outer framework seal is stable.
if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' library; do
        sign_file "$library"
    done < <(find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

    while IFS= read -r -d '' bundle; do
        sign_bundle "$bundle"
    done < <(find "$APP/Contents/Frameworks" -depth -type d \
        \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) -print0)
fi

# The app itself last, after every nested signature is in place.
codesign "${CODESIGN_ARGS[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Runtime Version|Timestamp" || true
echo "Signed and verified: $APP"
