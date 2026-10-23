#!/bin/bash
# vendor-telegram-helper.sh — build the Telegram MTProto helper and place it in
# Grabbit/Resources/bin/. Release builds should pass TELEGRAM_API_ID and
# TELEGRAM_API_HASH so the app ships app-level credentials; local development
# can omit them and use ~/.config/grabbit/telegram.env at runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Tools/telegram-helper"
OUT="Grabbit/Resources/bin"
mkdir -p "$OUT"

LDFLAGS=""
if [[ -n "${TELEGRAM_API_ID:-}" && -n "${TELEGRAM_API_HASH:-}" ]]; then
    LDFLAGS="-X main.defaultAPIID=$TELEGRAM_API_ID -X main.defaultAPIHash=$TELEGRAM_API_HASH"
    echo "building helper with app-level credentials"
else
    echo "building helper without embedded credentials (local dev env required)"
fi

# Match the app's architecture (project.yml pins ARCHS=arm64). CGO is
# disabled so the helper stays self-contained and can be built on an Intel
# release runner without a cross C toolchain.
HELPER_GOARCH="${TELEGRAM_HELPER_GOARCH:-arm64}"
echo "building helper for darwin/$HELPER_GOARCH"
(
    cd "$SRC"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$HELPER_GOARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "$OLDPWD/$OUT/grabbit-telegram-helper" .
)

codesign --force --sign - "$OUT/grabbit-telegram-helper"
chmod +x "$OUT/grabbit-telegram-helper"
echo "--- vendored ---"
ls -lh "$OUT/grabbit-telegram-helper"
