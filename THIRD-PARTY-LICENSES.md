# Third-Party Licenses

Grabbit bundles the following third-party components. Their licenses are
summarized below; full license texts ship in the DMG under `Licenses/`.

## Sparkle 2
- **What:** In-app software update framework.
- **License:** MIT
- **Source:** https://github.com/sparkle-project/Sparkle
- **Notes:** Linked as a Swift Package. Fully MIT-compatible.

## yt-dlp
- **What:** Media URL extractor (YouTube, X, TikTok, Instagram, etc.).
- **License:** The Unlicense (public domain)
- **Source:** https://github.com/yt-dlp/yt-dlp
- **Notes:** Bundled as a binary; not linked. Public domain — no obligations.

## ffmpeg / ffprobe
- **What:** Media transcoding and probing binaries.
- **License:** GPL or LGPL (depends on build flags — verify at pinning time)
- **Source:** https://ffmpeg.org
- **Notes:** Bundled as binaries; not linked. Prefer LGPL builds. If a GPL
  build is used, the binary is kept separate and noted in release notes.

## Deno
- **What:** JavaScript runtime for YouTube challenge solving.
- **License:** MIT
- **Source:** https://github.com/denoland/deno
- **Notes:** Bundled as a binary; not linked. MIT-compatible.

## aria2-next
- **What:** Torrent download engine (BitTorrent client).
- **License:** GPL-2.0-or-later
- **Source:** https://github.com/aria2/aria2 (aria2-next fork)
- **Notes:** Runs as a **separate process** communicating over JSON-RPC on
  localhost. Grabbit does not link against aria2 code. Per GPL, the binary
  is attributed here and the corresponding source is offered via the link
  above. Users receive the binary as part of Grabbit's distribution.

## Summary

Grabbit itself is MIT-licensed. The bundled binaries above are separate
programs (not linked libraries). GPL components (aria2, possibly ffmpeg)
are distributed as independent executables with attribution and source
references as required by their licenses.
