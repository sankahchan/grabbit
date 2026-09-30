# Chrome Web Store submission notes

Everything the Web Store dashboard asks for, pre-drafted. Package with
`./scripts/package-extension.sh` → upload `dist/grabbit-extension-v<version>.zip`.

## Listing

- **Name:** Grabbit Web Grabber
- **Summary (132 chars max):**
  Send videos, music and files from any website to the Grabbit download manager for macOS — one click, full quality.
- **Category:** Productivity
- **Language:** English
- **Homepage:** https://github.com/sankahchan/grabbit
- **Privacy policy URL:** https://github.com/sankahchan/grabbit/blob/main/PRIVACY.md

### Detailed description

```
Grabbit Web Grabber detects videos, music and downloadable files on the pages
you visit and hands them to the Grabbit download manager app on your Mac.

FEATURES
• Detects <video>/<audio> media and file links on any page
• Captures HLS/DASH streams and direct downloads with the browser's own
  cookies and Referer headers, so hotlink-protected files just work
• Telegram Web videos — including channels with "restrict saving content"
  disabled downloads — are captured from the page and imported into Grabbit
• Auto-grab browser downloads: downloads you start in Chrome are routed into
  Grabbit automatically (toggle in the popup)
• Right-click → "Download with Grabbit" on any video, audio or link
• Live capture progress notifications

REQUIREMENTS
• macOS 14+ on Apple Silicon
• The free Grabbit app (open source):
  https://github.com/sankahchan/grabbit
• One-time helper install to connect the extension to the app:
  ./GrabbitExtension/native-messaging/install-host.sh <extension-id>

PRIVACY
No data ever leaves your computer. URLs, page metadata and (for protected
downloads) login cookies are transmitted only to the Grabbit app on your Mac
through Chrome's native messaging API. No analytics, no tracking, no remote
servers. See PRIVACY.md.
```

## Single purpose

Hand media and download links from the browser to the local Grabbit download
manager app.

## Permission justifications

- **Host permission `<all_urls>`** — the download manager supports any site by
  design; media detection and request-context capture only run on pages the
  user visits and only produce data when the user activates the extension.
- **activeTab** — read the active tab's media list and act on it from the popup.
- **scripting** — inject MAIN-world helpers that fetch service-worker-served
  media (Telegram) and drive the page's own download pipeline; CSP-immune and
  always the packaged code (no remote code).
- **contextMenus** — the "Download with Grabbit" right-click entry.
- **nativeMessaging** — deliver downloads to the local Grabbit app (the only
  way an extension can talk to a Mac app).
- **cookies** — attach the user's login cookies to downloads they start, so
  authenticated files download exactly like they do in the browser. Sent only
  to the local app.
- **webRequest** — read request headers (Referer, User-Agent, Authorization)
  and observe media URLs so replayed downloads look like the browser's.
- **downloads** — route browser downloads into Grabbit (auto-grab toggle) and
  import finished Telegram downloads.
- **notifications** — capture progress and completion messages.
- **storage** — local preferences and pending-import bookkeeping.

## Privacy practices questionnaire

- **Data collected:** Website content (media/page URLs and titles) and
  Authentication information (cookies, only for downloads the user starts).
- **Purpose:** App functionality only.
- **Sold to third parties:** No.
- **Used/transferred for purposes unrelated to the single purpose:** No.
- **Used to determine creditworthiness/lending:** No.
- **Remote code:** No — all logic ships in the package.
- **Note for reviewers:** the "transfer" goes to the local Mac app over Chrome's
  native messaging channel; nothing is sent to any server.

## Reviewer test instructions

1. Load the extension and open any public page with an HTML5 video, or
   https://www.w3schools.com/html/html5_video.asp
2. Click the toolbar icon → the popup lists detected media.
3. Right-click a video → "Download with Grabbit" (on a machine without the
   Grabbit app, the extension shows "native host: unavailable" and a
   notification with the one-time helper install step — detection and popup
   behavior are fully testable without the app).
4. The "Auto-grab browser downloads" toggle (on by default) cancels browser
   downloads of media and reroutes them; turn it off to let Chrome download
   normally.

## After publishing

The Web Store assigns its own extension ID (shown in the dashboard). The
one-time helper must be installed for that ID, not the development ID:

```bash
./GrabbitExtension/native-messaging/install-host.sh <store-extension-id>
```

## Assets needed (dashboard)

- **Store icon:** 128×128 PNG (reuse `icons/icon128.png`).
- **Screenshots:** at least one 1280×800 (or 640×400) PNG — capture the popup
  over a page with detected media.
- **Small promo tile (optional):** 440×280 PNG.
