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

Replace `<extension-id>` with the ID from step 1.

This installs:
- The native messaging manifest for Chrome, Edge, Brave, and Chromium.
- The Python helper (`grabbit-native-helper.py`) to `~/Library/Application Support/Grabbit/`.

### 3. Test

1. Go to a page with a video (e.g. https://www.w3schools.com/html/mov_bbb.mp4).
2. Click the Grabbit extension icon.
3. Click **Download with Grabbit**.
4. If Chrome shows an "Open Grabbit?" prompt, click **Open Grabbit**.
5. The download appears in the Grabbit app.

## How it works

- The extension detects `<video>` tags and download links on the page.
- Clicking "Download with Grabbit" sends the URL to the native host via Chrome's native messaging API.
- The helper (`grabbit-native-helper.py`) receives the message and forwards it to the running Grabbit app via the `grabbit://` URL scheme.
- No second app instance is launched.

## Troubleshooting

- **"Access to the specified native messaging host is forbidden"**: The extension ID in the manifest doesn't match. Re-run `install-host.sh` with the correct ID.
- **"Native host has exited"**: The helper script may have an error. Check that Python 3 is installed: `python3 --version`.
- **Download doesn't start**: Make sure the Grabbit app is running. The helper forwards via URL scheme, which needs the app open.
