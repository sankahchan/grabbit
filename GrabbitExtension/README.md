# Grabbit Web Grabber — Browser Extension

Captures videos and download links from web pages and sends them to the Grabbit app.

## Install (Chrome / Edge / Brave)

The extension ships with every GitHub release (it is not on the Chrome Web
Store — video-downloader policy). The Grabbit app connects it automatically:

1. Download
   [grabbit-extension-latest.zip](https://github.com/sankahchan/grabbit/releases/latest/download/grabbit-extension-latest.zip)
   and unzip it.
2. Open `chrome://extensions`, turn on **Developer mode**, click **Load
   unpacked**, and select the unzipped folder.
3. Open the Grabbit app (v1.3.0+). On launch it installs the native helper
   and writes the browser host manifests for the extension automatically —
   no manual step.

**Updating:** download the new ZIP, replace the folder's contents, and press
the reload icon on the extension card.

### Development checkouts

If you run the extension straight from this repo instead, the app still
installs the helper automatically; `install-host.sh` remains for pinning a
custom extension ID (e.g. a store build):

```bash
./GrabbitExtension/native-messaging/install-host.sh <extension-id>
```

## Test

1. Go to a page with a video (e.g. https://www.w3schools.com/html/mov_bbb.mp4).
2. Click the Grabbit extension icon.
3. Click **Download with Grabbit**.
4. The download appears in the Grabbit app (with the host connected there is
   no "Open Grabbit?" prompt — the helper hands the payload over directly).

## How it works

- The extension detects `<video>`/`<audio>` tags, blob-backed media, and
  download links on the page.
- **URL downloads** go over Chrome native messaging (primary transport) to
  the helper, which writes the URL + captured request headers (Referer,
  Cookie, User-Agent, …) into `~/Library/Application Support/Grabbit/Inbox/`
  and opens `grabbit://download?payload=<file>` on the running app. Without
  the native host, a header-truncated `grabbit://` tab fallback is used.
- **Blob media** (Telegram Web videos/music that aren't MSE-protected) is
  fetched in-page and streamed to the helper as chunks.
- **Telegram restricted channels** (`restrict saving content`) stream through
  `MediaSource`. A page hook mirrors `SourceBuffer.appendBuffer` chunks
  (including the audio track) to the helper while the media plays — press
  **Save to Grabbit** in the popup to finalize; the app muxes video+audio with
  its bundled ffmpeg on import.
- **Blob downloads** started by the browser itself (Telegram's own Download
  button) are cancelled and captured in-page instead, so they still land in
  Grabbit.
- No second app instance is launched.

## Troubleshooting

- **"Access to the specified native messaging host is forbidden"**: The
  extension ID in the manifest doesn't match. Re-run `install-host.sh` with
  the correct ID.
- **"Native host has exited"**: The helper script may have an error. Check
  that Python 3 is installed: `python3 --version`.
- **Download doesn't start**: Make sure the Grabbit app is running. The
  helper forwards via URL scheme, which needs the app open.
- **Nothing captured for a Telegram restricted video**: open the video, let
  it play (capture starts automatically), then click the Grabbit popup and
  press **Save to Grabbit**. If it says "Failed", the video may have been
  replaced before the buffer was complete — reopen it, play it again, and
  save.
- **Stale captures**: partial captures are kept for 30 minutes and cleaned
  up automatically; the **Discard** button in the popup removes one
  immediately.

## Chrome Web Store publishing

```bash
./scripts/package-extension.sh
# → dist/grabbit-extension-v<version>.zip
```

The package contains runtime files only and strips the development `key`
field so the Web Store assigns the item ID. `STORE.md` has the listing copy,
permission justifications, privacy-practice answers and reviewer test steps.
After publishing, install the native helper for the **store** extension ID:

```bash
./GrabbitExtension/native-messaging/install-host.sh <store-extension-id>
```
