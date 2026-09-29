# Grabbit Web Grabber — Browser Extension

Captures videos and download links from web pages and sends them to the Grabbit app.

## Install (Chrome / Edge / Brave)

### 1. Load the extension

1. Open `chrome://extensions` in your browser.
2. Turn on **Developer mode** (top-right toggle).
3. Click **Load unpacked**.
4. Select the `GrabbitExtension` folder (from the repo, or from the DMG).
5. Note the **extension ID** shown under the Grabbit card (32 characters).

### 2. Install the native host

The extension talks to the Grabbit app via a lightweight helper. Install it:

```bash
./GrabbitExtension/native-messaging/install-host.sh <extension-id>
```

Replace `<extension-id>` with the ID from step 1. **Re-run this after every
pull** — the helper script is copied into `~/Library/Application Support/Grabbit/`.

This installs:
- The native messaging manifest for Chrome, Edge, Brave, and Chromium.
- The Python helper (`grabbit-native-helper.py`) to `~/Library/Application Support/Grabbit/`.

### 3. Test

1. Go to a page with a video (e.g. https://www.w3schools.com/html/mov_bbb.mp4).
2. Click the Grabbit extension icon.
3. Click **Download with Grabbit**.
4. The download appears in the Grabbit app. (With the native host installed
   there is no "Open Grabbit?" prompt — the helper hands the payload over
   directly.)

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
