# Roadmap

Statuses: ✅ shipped · 🔨 planned · 💭 idea / awaiting input

## Backlog

- 🔨 **New app icon(s)** — a fresh icon for Grabbit (AppIcon set, and the
  extension icons where relevant). Design TBD.
- 🔨 **New themes** — two designs reviewed and approved (saved in
  `docs/theme-previews/`):
  - **Aura** — clean airy SaaS, light + dark (FacilityFlow-inspired)
  - **Pulse** — dark neon download console, lime accent (Volta-inspired)

  Implementation is deferred: it needs a selectable theme-style system
  (palette + shape/shadow tokens) wired through Settings → Appearance.
  Mockups, tokens and re-render commands live in the theme-previews README.
- 💭 **Microsoft Edge Add-ons listing** — the Chrome Web Store item was
  permanently removed (downloader policy); Edge Add-ons accepts Chrome MV3
  packages and would give store presence + auto-updates. Reuse the store
  ZIP and the pre-drafted material in `GrabbitExtension/STORE.md`.
- 💭 **CLI / scriptable mode** — `grabbit <url> --best|--audio -o <dir>`
  via the URL scheme plus a shell wrapper (yoinks-inspired).
- 💭 **Fair-use note** in README (prudent after the Web Store enforcement).
- 💭 **Intel (x86_64) support** — pending decisions: DMG size (~250–300 MB)
  acceptance and the ffmpeg arm64 binary source (osxexperts pinned vs
  CI-built).
- 💭 **Notarization / Developer ID** — deferred; needs an Apple Developer
  account. Sparkle EdDSA already protects updates in the meantime.

## Shipped (recent)

- v1.6.0 — one-click extension updates from the Grabber tab; the full
  extension package ships an en/my `INSTALL.txt` guide.
- v1.5.x — "What's New" sheet after every update, release notes in the
  Sparkle dialog, build-number/update-loop fix.
- v1.4.x — RSS subscriptions, media post-processing (metadata/subtitles),
  cookies.txt import, UI polish.
- v1.3.0 — bundled native helper auto-install (no manual `install-host.sh`).
- v1.2.x — security hardening (Keychain host passwords, payload cleanup,
  yt-dlp checksum verification, zip-slip tests, log redaction).
