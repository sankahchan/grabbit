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
- **How it's vendored:** the `release.yml` workflow downloads the universal2 macOS build (`yt-dlp_macos` from the yt-dlp GitHub releases) with `curl -L`, drops it into `Grabbit/Resources/bin/`, and marks it executable. At build time the app copies it to `App.app/Contents/Resources/bin/`. The binary is **not** committed to git (see `.gitignore`).
- **Version pinning:** currently pulled from `/releases/latest/download/`. Before public release, pin to a fixed tag (e.g. `yt-dlp_macos` for `2026.09.27`) so builds are reproducible, and bump on a cadence — monthly, or whenever a supported site breaks.
- **License:** The Unlicense (public domain). Compatible with MIT; attribution kept in the About box.

## ffmpeg (bundled binary)

- **What:** the standard media transcoder; used for MP3 extraction (and any future remuxing).
- **Why:** a battle-tested static binary beats shipping our own encoder.
- **How it's vendored:** same as yt-dlp — `release.yml` downloads a static macOS build into `Grabbit/Resources/bin/` (currently `ffmpeg-static`'s `ffmpeg-darwin-x64` asset). Not committed to git.
- **Version pinning:** pin to a fixed release tag before public release, alongside yt-dlp.
- **License:** ffmpeg static builds are typically GPL or LGPL depending on compile flags. The maintainer's build used here should be checked at pinning time: prefer an LGPL build, and if a GPL build is unavoidable, keep the binary clearly separated and note it in the release notes. This is the one dependency to double-check before shipping publicly.

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
| ffmpeg (static binary) | GPL or LGPL (verify at pinning) | ⚠️ verify build flags before public release |
| libtorrent | BSD-3-Clause | ✅ yes (keep notice) |
| Extension | none (own code) | ✅ yes |
