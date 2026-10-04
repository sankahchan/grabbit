# Grabbit

<p align="center">
  <img src="docs/icon.png" width="128" alt="Grabbit icon">
</p>

[![CI](https://img.shields.io/github/actions/workflow/status/sankahchan/grabbit/ci.yml?branch=main&label=CI)](https://github.com/sankahchan/grabbit/actions)
[![Latest release](https://img.shields.io/github/v/release/sankahchan/grabbit?label=release)](https://github.com/sankahchan/grabbit/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Grabbit** is an IDM-style download manager for macOS — native SwiftUI, Apple Silicon only. Grab links, torrents, and site videos fast with multi-connection segmented downloads, and pick up exactly where you left off even if the app is killed mid-download. Bilingual UI: English + မြန်မာ.

## Screenshots

|  |  |
|---|---|
| ![New Download](docs/screenshots/add-download.png) | ![Downloads](docs/screenshots/downloads.png) |
| Add downloads with per-task options | Segmented multi-connection downloads |
| ![Torrents](docs/screenshots/torrents.png) | ![Media probe](docs/screenshots/media-probe.png) |
| Torrents via the bundled aria2-next daemon | Site downloads via yt-dlp (quality presets) |
| ![Media download](docs/screenshots/media-download.png) | |
| Live yt-dlp progress with speed and ETA | |

## Features

- **Segmented multi-connection downloads** — splits files into parallel HTTP Range segments for maximum speed.
- **Crash-safe resume** — download state is autosaved every ~5s atomically; killing the app mid-download resumes cleanly on next launch. Applies to direct downloads **and** torrents.
- **Torrent & magnet support** — via a managed [aria2-next](https://github.com/AnInsomniacy/aria2-next) daemon (JSON-RPC), with per-torrent file selection, share-ratio / seed-time limits, session persistence across restarts, and an optional VPN-interface kill-switch.
- **yt-dlp site downloads** — YouTube, X, TikTok, Instagram, and more via a bundled `yt-dlp` binary.
- **Telegram Web grab** — a Chrome / Safari browser extension (Native Messaging) captures blob videos from `web.telegram.org`.
- **MP3 extraction** — bundled `ffmpeg` converts videos to audio with one click.
- **Download scheduler** — queue downloads for off-peak hours.
- **Bilingual UI** — English and Burmese (`Localizable.xcstrings`) with an in-app language switcher.
- **Sparkle auto-updates** — updates ship through GitHub Releases.

## Install

1. Download the latest `Grabbit-*.dmg` from [Releases](https://github.com/sankahchan/grabbit/releases/latest).
2. Open it, drag **Grabbit.app** to Applications.
3. **First launch:** Right-click Grabbit.app → **Open** → click **Open** in the dialog.
   (This is needed once because early builds are unsigned. Double-clicking may
   show a "damaged" warning — that's macOS Gatekeeper, not a broken download.)
4. macOS 14+ on Apple Silicon required.

> ⚠️ Early builds are unsigned. Developer ID signing + notarization are planned —
> until then, use Right-click → Open on first launch. Advanced users can also run:
> `sudo xattr -cr /Applications/Grabbit.app`

## Browser Extension

The Grabbit Web Grabber extension captures media from web pages. It is not
on the Chrome Web Store (video-downloader policy), so it ships with every
GitHub release:

1. Download
   [grabbit-extension-latest.zip](https://github.com/sankahchan/grabbit/releases/latest/download/grabbit-extension-latest.zip)
   (stable link, always the newest build) and unzip it.
2. Open `chrome://extensions` → enable **Developer mode** → **Load unpacked**
   → pick the unzipped folder. (Works in Edge/Brave the same way.)
3. Install the Grabbit app — v1.3.0+ connects the extension automatically on
   launch. Older builds: run
   `./GrabbitExtension/native-messaging/install-host.sh <extension-id>`.
4. See [GrabbitExtension/README.md](GrabbitExtension/README.md) for details.

## Build from source

Prerequisites: Xcode 15+, macOS 14+, [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/sankahchan/grabbit.git
cd grabbit
brew install xcodegen
xcodegen generate
open Grabbit.xcodeproj
```

Build with `⌘B`, run tests with `⌘U`. CI does the same on every push to `main`.

> After `git pull`, re-run `xcodegen generate` — the `.xcodeproj` only knows
> the files that existed when it was generated, so new `.swift` files won't
> compile until you regenerate.

## Project layout

| Path | Contents |
|---|---|
| `Grabbit/App` | SwiftUI entry point, app state |
| `Grabbit/Models` | Download models, state schema |
| `Grabbit/Engine` | URLSession segmented engine, torrent engine (managed aria2-next daemon over JSON-RPC) |
| `Grabbit/NativeMessaging` | Native-messaging host for the browser extension |
| `Grabbit/UI` | Views (neo-brutalist design) |
| `Grabbit/Resources` | Assets, `Localizable.xcstrings`, vendored `bin/` (yt-dlp, ffmpeg, aria2-next — downloaded at release build time) |
| `GrabbitExtension/` | Chrome MV3 extension + native-messaging helper |
| `.github/workflows` | `ci.yml` (build + test), `release.yml` (DMG + appcast) |
| `ARCHITECTURE.md` | Design deep-dive |
| `DEPENDENCIES.md` | Third-party components and licenses |
| `CONTRIBUTING.md` | How to contribute and cut a release |

## မြန်မာလို အကျဉ်းချုပ်

**Grabbit** သည် macOS အတွက် download manager တစ်ခုဖြစ်သည် — SwiftUI ဖြင့် ရေးသားထားပြီး Apple Silicon သီးသန့် ဖြစ်သည်။

- ဖိုင်များကို အပိုင်းခွဲ၍ တစ်ပြိုင်နက် မြန်မြန်ဆန်ဆန် ဒေါင်းလုဒ်လုပ်ခြင်း (multi-connection)
- အက်ပ် ပိတ်သွားခြင်း / crash ဖြစ်ခြင်းများမှ ပြန်လည်စတင်နိုင်ခြင်း — direct download ရော torrent ရော
- Torrent နှင့် magnet link များ ပံ့ပိုးခြင်း
- YouTube, X, TikTok, Instagram မှ ဗီဒီယိုများ ဒေါင်းလုဒ်လုပ်နိုင်ခြင်း (yt-dlp)
- Telegram Web မှ ဗီဒီယိုများ ဖမ်းယူနိုင်ခြင်း (browser extension)
- MP3 အဖြစ်သို့ ပြောင်းလဲနိုင်ခြင်း (ffmpeg)
- မြန်မာဘာသာ UI ပါဝင်ခြင်း၊ Sparkle ဖြင့် အလိုအလျောက် update

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests welcome — please add Burmese strings for any new UI text.

## License

MIT — see [LICENSE](LICENSE).
