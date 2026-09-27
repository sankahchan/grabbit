# Dependencies

Everything Grabbit depends on that isn't Apple's SDK, and why it's there.

## Sparkle 2 (Swift Package Manager)

- **What:** the standard macOS in-app update framework.
- **Why:** ships updates through the appcast at `https://github.com/sankahchan/grabbit/releases/latest/download/appcast.xml`, with a familiar update UI users already trust.
- **Integration:** added via SPM (`https://github.com/sparkle-project/Sparkle`). The feed URL is set in code/config so updates resolve to the GitHub Releases page.
- **License:** MIT — fully compatible.
- **Note:** EdDSA signature verification (`sparkle:edSignature`) is wired but unsigned builds can't use it yet. It's a TODO alongside Developer ID signing before public distribution.

## yt-dlp (bundled binary)

- **What:** the community-maintained youtube-dl fork; extracts direct media URLs from YouTube, X, TikTok, Instagram, and hundreds more sites.
- **Why:** writing and maintaining per-site extractors is a full-time job — yt-dlp does it better and stays current.
- **How it's vendored:** `scripts/vendor-media-runtime.sh` (run by `release.yml`) downloads the pinned universal2 macOS build (`yt-dlp_macos`) into `Grabbit/Resources/bin/`; the `Install media runtime into Resources` post-build script copies it to `App.app/Contents/Resources/bin/` at build time. The binary is **not** committed to git (see `.gitignore`).
- **Version pinning:** pinned to a fixed tag inside the vendor script (e.g. `2026.09.27`) so builds are reproducible; bump on a cadence — monthly, or whenever a supported site breaks.
- **Independent updates:** `MediaComponentUpdater` can replace yt-dlp on its own cadence (sites break weekly) by dropping a newer binary into `~/Library/Application Support/Grabbit/bin/`, which `MediaRuntimeResolver` prefers over the bundled copy.
- **Resolution order** (`MediaRuntimeResolver`): bundled Resources → user-updated copies → `YTDLP_PATH` env override → `/opt/homebrew/bin` → `PATH`. Failures produce human-readable install hints.
- **License:** The Unlicense (public domain). Compatible with MIT; attribution kept in the About box.

## ffmpeg / ffprobe (bundled binaries)

- **What:** the standard media transcoder; used for MP3 extraction (`-x --audio-format mp3`), stream merging (`bv*+ba`), and remuxing.
- **Why:** a battle-tested static binary beats shipping our own encoder.
- **How it's vendored:** same pipeline as yt-dlp — `scripts/vendor-media-runtime.sh` downloads a static **arm64** build (evermeet.cx) into `Grabbit/Resources/bin/`; the post-build script installs it into the app. When `VENDOR_FROM_HOMEBREW=1`, Homebrew's ffmpeg/ffprobe are copied instead and non-system dylibs are relocated into `Grabbit/Resources/lib/` via `install_name_tool` (`@executable_path/../lib/<name>`), then everything is ad-hoc re-signed. Not committed to git.
- **Version pinning:** pinned alongside yt-dlp in the vendor script.
- **License:** ffmpeg static builds are typically GPL or LGPL depending on compile flags. The maintainer's build used here should be checked at pinning time: prefer an LGPL build, and if a GPL build is unavoidable, keep the binary clearly separated and note it in the release notes. This is the one dependency to double-check before shipping publicly.

## Deno (bundled binary)

- **What:** the JS runtime yt-dlp 2026+ needs to solve YouTube's anti-bot JS challenges — without it, YouTube downloads fail.
- **How it's vendored:** `scripts/vendor-media-runtime.sh` downloads the pinned `deno-aarch64-apple-darwin.zip` into `Grabbit/Resources/bin/` (or copies Homebrew's deno with dylib relocation). Its directory is injected into `PATH` for yt-dlp child processes; also resolvable via `DENO_PATH`.
- **License:** MIT. Compatible.

## aria2-next (bundled binary — torrent engine)

- **What:** an actively maintained aria2 fork (`AnInsomniacy/aria2-next`) — a battle-tested C++ download engine with BitTorrent (DHT, magnets, seeding), driven by Grabbit over JSON-RPC from the `Aria2RPC` Swift actor.
- **Why:** delegating to a maintained engine beats hand-rolling libtorrent (the earlier plan) — fastest path to a shippable, correct torrent implementation, and the same engine Motrix uses.
- **Decision:** `AnInsomniacy/aria2-next` was verified (2026-09-28) as the maintained fork — recent releases (v2.8.2 latest at pinning time), prebuilt **macOS arm64** binaries, per-release SHA-256 checksums. The older `motrixapp/aria2` fork is Motrix-specific and less active.
- **How it's vendored:** `scripts/vendor-torrent-runtime.sh` (run by `release.yml`) downloads the pinned `aria2-next-<version>-macos-arm64` asset into `Grabbit/Resources/bin/aria2-next`; the post-build script installs it into the app. The script verifies the checksums file against the pinned SHA-256 and refuses to vendor on mismatch. Not committed to git.
- **Version pinning:** pinned to a fixed tag + SHA-256 inside the vendor script; bump on a cadence.
- **Runtime management:** `Aria2Daemon` spawns/manages the child process with a versioned ownership manifest (`~/Library/Application Support/Grabbit/aria2-daemon.plist`: pid, binary path, RPC port, secret, start signature) — reclaims live owned daemons, kills stale/foreign ones. Session persistence via `--save-session` + `--bt-save-metadata`/`--bt-load-saved-metadata`; Grabbit additionally persists GIDs in `torrents.json` and reconciles by info-hash on start.
- **Resolution order** (`TorrentRuntimeResolver`): bundled Resources → `~/Library/Application Support/Grabbit/bin` → `ARIA2_NEXT_PATH` env override → Homebrew (`aria2-next`, then upstream `aria2c` fallback) → `PATH`.
- **License:** GPL-2.0-or-later. The binary is a separate program communicated with over JSON-RPC; Grabbit's own source stays MIT. The vendoring script lives next to this manifest so the attribution/source-offer obligation stays visible. Mention in release notes.

## Browser extension (no dependencies)

- **What:** Chrome MV3 + Safari Web Extension built from shared JS in `extension/`.
- **Why it's needed:** sites like `web.telegram.org` serve media as blobs that a page can't hand to a download manager — the extension grabs the video URL and sends it to the app over Native Messaging (`com.sankahchan.grabbit`).
- **Dependencies:** none — vanilla JS, no build step, no npm packages.

## License compatibility summary

| Component | License | Compatible with MIT distribution? |
|---|---|---|
| Sparkle 2 | MIT | ✅ yes |
| yt-dlp | The Unlicense | ✅ yes |
| ffmpeg / ffprobe (static binary) | GPL or LGPL (verify at pinning) | ⚠️ verify build flags before public release |
| Deno | MIT | ✅ yes |
| aria2-next (binary) | GPL-2.0-or-later | ⚠️ separate program over JSON-RPC; attribute + source offer in release notes |
| Extension | none (own code) | ✅ yes |
