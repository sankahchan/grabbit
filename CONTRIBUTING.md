# Contributing to Grabbit

Thanks for wanting to help. Grabbit is MIT-licensed and community-driven — issues, PRs, and Burmese translations are all welcome.

## Prerequisites

- macOS 14+ on Apple Silicon
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Getting started

```bash
git clone https://github.com/sankahchan/grabbit.git
cd grabbit
xcodegen generate
open Grabbit.xcodeproj
```

Run the app with `⌘R`, run tests with `⌘U`.

## Branching

- `main` is always releasable. CI builds + tests every push and PR to `main`.
- Branch off `main` for your work: `feature/<name>`, `fix/<name>`, `docs/<name>`.
- Open a PR back into `main`. Keep PRs focused — one change per PR.

## PR checklist

Before requesting review:

- [ ] `xcodebuild -scheme Grabbit -destination 'platform=macOS' build` passes (CI checks this too).
- [ ] `xcodebuild test -scheme Grabbit -destination 'platform=macOS'` passes.
- [ ] Every new user-visible string is added to `Localizable.xcstrings` in **both** `en` and `my` (Burmese). A PR without Burmese strings is incomplete.
- [ ] No secrets: no API keys, tokens, credentials, or private identifiers anywhere in code, assets, or commit messages.
- [ ] Public API changes are reflected in `ARCHITECTURE.md` if they touch a documented design decision.
- [ ] Follow the existing Swift style (SwiftUI + `@MainActor` state mutations, see `ARCHITECTURE.md`).

## Release process

Releases are cut by tagging — no manual steps needed:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The `release.yml` workflow then:

1. Generates the Xcode project and vendors `yt-dlp` + `ffmpeg` into `Grabbit/Resources/bin/`.
2. Builds the Release configuration (currently unsigned — see signing TODO).
3. Packages `Grabbit.app` into a DMG with `hdiutil`.
4. Creates the GitHub Release and attaches the DMG.
5. Updates `appcast.xml` on `main` with a new `<item>` so Sparkle notifies existing users.

### Before the first public release

- [ ] Pin `yt-dlp`/`ffmpeg` binary URLs to fixed release tags (see `DEPENDENCIES.md`).
- [ ] Set up Developer ID signing + notarization + Hardened Runtime in `release.yml`.
- [ ] Configure `SUPublicEDKey` and generate `sparkle:edSignature` via Sparkle's `generate_appcast` tool.
