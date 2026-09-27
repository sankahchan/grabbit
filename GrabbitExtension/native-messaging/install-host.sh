#!/usr/bin/env bash
# Installs the Grabbit native-messaging host manifest for Chromium-based browsers
# (and notes the Firefox location).
#
# Usage: ./install-host.sh <extension-id>
#   where <extension-id> is the ID shown on chrome://extensions after loading
#   GrabbitExtension in developer mode. It replaces the REPLACE_WITH_EXTENSION_ID
#   placeholder in the manifest before installing.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <extension-id>   (see chrome://extensions)" >&2
  exit 1
fi

EXT_ID="$1"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/com.sankahchan.grabbit.json"
NAME="com.sankahchan.grabbit.json"

# Chromium-family destinations on macOS.
declare -a DESTS=(
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
)

for dir in "${DESTS[@]}"; do
  mkdir -p "$dir"
  sed "s/REPLACE_WITH_EXTENSION_ID/$EXT_ID/" "$SRC" > "$dir/$NAME"
  echo "Installed -> $dir/$NAME"
done

# Firefox uses the same manifest file (different directory):
#   ~/Library/Application Support/Mozilla/NativeMessagingHosts/
# and requires "allowed_origins" replaced with the Firefox extension ID.
echo "Note: for Firefox, install the same file into:"
echo "  $HOME/Library/Application Support/Mozilla/NativeMessagingHosts/$NAME"
