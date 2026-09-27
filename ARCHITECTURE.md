# Architecture

How Grabbit is put together. Read this before making structural changes.

## Module map

```
Grabbit/
├── App/                 SwiftUI @main entry, AppState (single @MainActor source of truth)
├── Models/              Download, TorrentDownload, segment bitmaps, state JSON schema
├── Engine/
│   ├── DownloadEngine   URLSession segmented downloader (direct HTTP(S))
│   ├── SiteEngine       shells out to bundled yt-dlp, parses progress JSON
│   ├── MediaEngine      shells out to bundled ffmpeg for MP3 extraction
│   ├── TorrentEngine     managed aria2-next daemon over JSON-RPC (Aria2Daemon, Aria2RPC actor)
│   └── Scheduler        time-windowed queue execution
├── NativeMessaging/     stdio host: reads 4-byte LE length-prefixed JSON from the browser extension
├── UI/                  SwiftUI views, neo-brutalist design system
└── Resources/           Assets, Localizable.xcstrings, bin/ (vendored yt-dlp + ffmpeg + aria2-next)
extension/               Chrome MV3 + Safari Web Extension (shared JS, no build step)
```

Communication is one-directional where possible: engines report progress to `AppState` via `AsyncStream`/delegates; views only read `AppState`.

## Download engine (direct HTTP)

- **Segmented Range downloads.** Each download is split into N segments (default 8, user-configurable 1–16). Every segment is an independent `URLSessionDataTask` issuing `Range: bytes=start-end`. Segments write to non-overlapping offsets of the same partial file.
- **Connection count.** Bounded by a per-download segment count and a global concurrent-download cap; the scheduler keeps both under limits.
- **Speed calculation.** A rolling 3-second window of received bytes per download; the UI polls the engine at 1 Hz and renders from the window average, not instantaneous spikes.

## Resume & crash-safety design

This is the core promise: **kill the app mid-download and lose nothing.**

- **State schema.** Each download has a JSON state file in `~/Library/Application Support/Grabbit/States/<id>.json`:
  ```json
  {
    "url": "https://…",
    "destination": "/Users/…/file.zip",
    "totalBytes": 123456789,
    "segments": [{"start": 0, "end": 2097151, "done": 1048576}],
    "status": "downloading"
  }
  ```
  The per-segment `done` byte counts make resume exact to the byte.
- **5s autosave.** The engine snapshots state every ~5 seconds during active downloads.
- **Atomic writes.** State is written to a temp file then moved over the real one with `FileManager.replaceItemAt` — a crash mid-write can never leave a corrupt state file.
- **`.grabbit-part` files.** In-progress downloads live as `<name>.grabbit-part`; the suffix is stripped only after the final byte is verified complete.
- **Launch recovery.** On startup the app scans `States/`, marks anything left in `downloading` as `interrupted`, and offers **Resume All**. No user action is required to pick up where things left off.
- **Torrents.** A managed aria2-next daemon persists its own session (`--save-session` every 30s + on shutdown, `--bt-save-metadata`/`--bt-load-saved-metadata` for magnets) in `~/Library/Application Support/Grabbit/aria2/`; Grabbit additionally persists per-torrent records (`torrents.json`) on every mutation and reconciles by info-hash on startup, re-adding anything the daemon lost. A versioned ownership manifest (`aria2-daemon.plist`) lets a new app instance reclaim a live owned daemon instead of spawning a duplicate. Same kill-and-resume guarantee as direct downloads.

## Threading model

- **All state mutations on `@MainActor`.** `AppState` and view models never touch shared state off the main actor.
- **Background URLSession tasks.** `URLSession` delegate callbacks arrive on a background queue; they forward progress into `AsyncStream`s and hop to `@MainActor` only when mutating state. The 5s autosave runs on a background task reading an immutable snapshot.
- **Cancellation = pause.** Cancelling a download cancels its tasks, flushes a final state write, and leaves the state file ready for resume. There is no destructive "cancel"; deletion is an explicit separate action.

## Native messaging protocol

The browser extension talks to the app over Chrome Native Messaging:

1. Extension launches the host (`com.sankahchan.grabbit`) via stdio.
2. Every message is **4-byte little-endian length prefix + UTF-8 JSON**.
3. Message types: `{ "type": "grab", "url": "…", "filename": "…", "cookies": "…" }` for a new download; `{ "type": "ping" }` for liveness.
4. The host validates the origin (extension IDs are allow-listed) and hands grabs to `AppState` on `@MainActor`.

This is what makes Telegram Web (`web.telegram.org`) blob videos downloadable — the extension captures the blob URL inside the page and forwards it.

## Update flow (Sparkle)

1. `release.yml` publishes the DMG as a GitHub Release asset.
2. The same workflow prepends an `<item>` to `appcast.xml` on `main`.
3. `https://github.com/sankahchan/grabbit/releases/latest/download/appcast.xml` always serves the newest feed.
4. Sparkle 2 in the app polls the feed and presents the update UI.
5. (TODO) `sparkle:edSignature` verification once `SUPublicEDKey` is configured and the release workflow uses `generate_appcast` with the private key.

## Why not sandboxed

Grabbit is distributed **outside** the App Store and is deliberately not sandboxed:

- Downloads must write to arbitrary user-chosen paths.
- The engine shells out to `yt-dlp` / `ffmpeg` subprocesses.
- The native-messaging host needs stdio pipes from the browser.

Sandboxing would break all three. The tradeoff is explicit: no App Store distribution, and users must trust the Developer ID signature — which is why **Developer ID signing + notarization + Hardened Runtime** are a blocking TODO before public distribution.

## i18n approach

- All user-visible strings live in `Resources/Localizable.xcstrings` (String Catalog), with `en` and `my` (Burmese) localizations.
- An in-app language switcher overrides the system locale at runtime.
- PR rule: any new UI string ships with both `en` and `my` translations or the PR is incomplete.
