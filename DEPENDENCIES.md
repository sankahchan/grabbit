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

## libtorrent (planned)

- **What:** the mature C++ BitTorrent library behind qBittorrent and many others.
- **Why:** robust DHT, magnet, and fast-resume support that a hand-rolled torrent client can't match.
- **Plan:** add as a git submodule at `extern/libtorrent`, build a static library with CMake, and bridge it to Swift through the Objective-C++ layer at `Grabbit/Engine/LibTorrent/LTSessionBridge.h/.mm`. Until then the torrent engine is a documented stub behind `TorrentEngineProtocol`.
- **Fast resume:** libtorrent fast-resume data is saved every 60s and on pause/shutdown, atomically, to `<id>.fastresume` next to the download states — so torrents survive kills just like direct downloads.
- **License:** BSD-3-Clause — compatible with MIT. Keep the BSD notice with the vendored source.

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
| libtorrent | BSD-3-Clause | ✅ yes (keep notice) |
| Extension | none (own code) | ✅ yes |
