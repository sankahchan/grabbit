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

1. Generates the Xcode project and vendors `yt-dlp` + `ffmpeg` + `aria2-next` into `Grabbit/Resources/bin/`.
2. Builds the Telegram helper from `Tools/telegram-helper/` (app-level API credentials come from Actions secrets).
3. Builds the Release configuration, then signs the app, vendored helpers, and Sparkle framework with a Developer ID identity and Hardened Runtime.
4. Packages `Grabbit.app` into a DMG and notarizes + staples it.
5. Creates the GitHub Release and attaches the DMG.
6. Updates `appcast.xml` on `main` with a new `<item>` so Sparkle notifies existing users.

Public tags **fail closed** if the Developer ID/notary secrets are missing. For an
internal unsigned test tag only, set the repository variable
`ALLOW_UNSIGNED_RELEASE=true`; remove it before a public release.

### Before the first public release

- [ ] Pin `yt-dlp`/`ffmpeg` binary URLs to fixed release tags (see `DEPENDENCIES.md`).
- [ ] Configure the Developer ID certificate and notary secrets in [SIGNING.md](SIGNING.md).
- [ ] Configure `SPARKLE_PRIVATE_KEY`; `SUPublicEDKey` is already in `project.yml`.
- [ ] Resolve any exposed Telegram API credentials with Telegram support (Telegram has no self-service API hash rotation), then set `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`.
- [ ] Run the full Swift suite plus Debug/Release builds, and `go test ./...` in `Tools/telegram-helper`.
