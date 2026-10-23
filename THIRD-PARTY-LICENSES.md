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

## gotd/td
- **What:** Telegram MTProto client library used by the separate
  `grabbit-telegram-helper` process.
- **License:** MIT
- **Source:** https://github.com/gotd/td
- **Notes:** Compiled into a helper executable; Grabbit does not link it into
  the app. Helper source is included under `Tools/telegram-helper/`. The helper
  also builds on MIT/BSD-licensed transitive Go modules listed in its `go.sum`.
  MIT-compatible.

## Mochi Icons
- **What:** Sticker-style `Search` and `Bookmark` artwork used in the Classic
  theme's Telegram empty states.
- **License:** MIT
- **Copyright:** Copyright (c) 2026 Mochi Icons Contributors
- **Source:** https://mochi-icons.com/ (npm package `mochi-icons` 0.2.1)
- **Notes:** Selected artwork was exported to static PNG assets with its
  transparent padding trimmed. Grabbit does not bundle React or the npm
  package at runtime. The Telegram paper-plane and Mini Apps grid stickers
  are original Grabbit artwork rendered in the same die-cut style.

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

## Mochi Icons MIT license text

Copyright (c) 2026 Mochi Icons Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
