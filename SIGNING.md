# Code Signing, Notarization & Release Credentials

Grabbit releases are intended to be **Developer ID signed, hardened-runtime
protected, and notarized**. The workflow is ready for that path, but it is
gated: a tag will not publish an unsigned public release unless the repository
variable `ALLOW_UNSIGNED_RELEASE=true` is set for an internal test build.

## Current status

This Mac currently has **no valid Developer ID identities** and no
`notarytool` keychain profile named `grabbit`:

```sh
security find-identity -v -p codesigning
# 0 valid identities found

xcrun notarytool history --keychain-profile grabbit
# Error: No Keychain password item found for profile: grabbit
```

That is the only blocker for the actual signing/notarization run. The
workflow, signing script, and secret contract below are complete and can be
exercised once the certificate and Apple credentials exist.

## 1. Apple Developer Program

- Enroll at https://developer.apple.com/programs/ ($99/year).
- Developer ID signing is required for distribution outside the App Store.

## 2. Create a Developer ID Application certificate

1. Open **Keychain Access** → **Certificate Assistant** → **Request a
   Certificate From a Certificate Authority**.
2. Save the `.certSigningRequest`.
3. Go to https://developer.apple.com/account/resources/certificates/.
4. Click **+** → **Developer ID Application** → upload the request → download
   the `.cer`.
5. Double-click the `.cer` to install it in the login keychain.

Verify the exact identity name:

```sh
security find-identity -v -p codesigning
# "Developer ID Application: Your Name (TEAMID)"
```

## 3. Export the certificate for CI

The workflow imports a base64-encoded `.p12` into a temporary keychain. In
**Keychain Access**, select the Developer ID Application certificate **and its
private key**, right-click → **Export 2 items…**, choose `.p12`, and set a
strong export password.

Base64-encode it (macOS):

```sh
base64 -i DeveloperID.p12 | pbcopy
```

Do not commit the `.p12`, its password, or the base64 output. The runner
deletes the decoded file immediately after import.

## 4. Create an app-specific password

1. Go to https://appleid.apple.com → **Sign-In and Security** →
   **App-Specific Passwords** → generate one for `Grabbit notarization`.
2. Save it securely. This is **not** your Apple ID password.

## 5. Configure GitHub Actions secrets

Set these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | base64 of the `.p12` from step 3 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | password chosen when exporting the `.p12` |
| `DEVELOPER_ID_IDENTITY` | exact `Developer ID Application: … (TEAMID)` string |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from step 4 |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (see below) |
| `TELEGRAM_API_ID` | Telegram app API ID used to build the helper |
| `TELEGRAM_API_HASH` | Telegram app API hash used to build the helper |

With `gh`:

```sh
gh secret set DEVELOPER_ID_CERTIFICATE < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set DEVELOPER_ID_IDENTITY
gh secret set APPLE_ID
gh secret set APPLE_TEAM_ID
gh secret set APPLE_APP_SPECIFIC_PASSWORD
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private.pem
gh secret set TELEGRAM_API_ID
gh secret set TELEGRAM_API_HASH
```

For an **internal, unsigned** test tag only, explicitly opt in:

```sh
gh variable set ALLOW_UNSIGNED_RELEASE --body true
```

Remove that variable (`gh variable delete ALLOW_UNSIGNED_RELEASE`) before a
public release. Without it, a tag with missing signing secrets fails in the
`Check release credentials` step rather than publishing a build that Gatekeeper
will block.

## 6. What the release workflow does

`.github/workflows/release.yml`:

1. Checks the signing/notary secrets and refuses an unsigned public release
   unless `ALLOW_UNSIGNED_RELEASE=true`.
2. Builds the app **unsigned** so all nested code can be signed explicitly.
3. Aligns `CFBundleShortVersionString` / `CFBundleVersion` with the tag.
4. Imports the Developer ID certificate into a temporary keychain.
5. Runs `scripts/sign-app.sh`, which signs, in order:
   - vendored executables in `Contents/Resources/bin` (`yt-dlp`, `ffmpeg`,
     `ffprobe`, `deno`, `aria2-next`, `grabbit-telegram-helper`),
   - vendored dylibs in `Contents/Resources/lib`,
   - `Sparkle.framework` and its nested `Updater.app` / XPC services,
   - the outer `Grabbit.app`.
   Every signature uses `--options runtime` (Hardened Runtime) and
   `--timestamp`. The script verifies the result with
   `codesign --verify --deep --strict`.
6. Creates the DMG.
7. Submits the DMG to Apple's notary service, waits, staples the ticket, and
   checks it with `stapler validate` and `spctl`.
8. Publishes the release and updates `appcast.xml` with Sparkle's EdDSA
   signature.
9. Deletes the temporary keychain even if an earlier step failed.

No entitlements file is currently required: Grabbit is not sandboxed and does
not use JIT, camera, microphone, or other restricted resources. Hardened
Runtime still permits the child processes Grabbit launches. If a future
feature needs an entitlement, add it to a shared `.entitlements` file and pass
it to the outer app signature (and only that target, unless a helper needs it).

## 7. Local signing and verification

After building the app with the vendored runtimes:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/sign-app.sh /path/to/Grabbit.app
```

For local notarization, store credentials once:

```sh
xcrun notarytool store-credentials grabbit \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD"
```

Then notarize the DMG (the workflow uses the environment variables directly):

```sh
xcrun notarytool submit dist/Grabbit-vX.Y.Z.dmg \
  --keychain-profile grabbit --wait
xcrun stapler staple dist/Grabbit-vX.Y.Z.dmg
xcrun stapler validate dist/Grabbit-vX.Y.Z.dmg
spctl --assess --type open --context context:primary-signature -v \
  dist/Grabbit-vX.Y.Z.dmg
```

Useful checks on the app itself:

```sh
codesign --verify --deep --strict --verbose=2 Grabbit.app
codesign -dv --verbose=4 Grabbit.app
spctl --assess --type execute --verbose=4 Grabbit.app
```

## 8. Sparkle EdDSA key

The Sparkle private key is **not** in this repository. Keep a secure backup:
if it is lost, existing installs cannot verify future updates. The public key
is already in `project.yml` as `SUPublicEDKey`.

`release.yml` downloads Sparkle's `sign_update` tool, signs the DMG, and puts
the bare signature into the appcast. If `SPARKLE_PRIVATE_KEY` is missing, the
workflow warns and omits the signature; Sparkle will reject the update, which
is the safe failure mode.

## 9. Telegram helper credentials

The helper is built by `scripts/vendor-telegram-helper.sh`. Release builds pass
`TELEGRAM_API_ID` and `TELEGRAM_API_HASH` via `-ldflags` so end users never
enter them. These values are recoverable from the shipped binary, which is
normal for desktop Telegram clients; they are still app-level credentials and
must not be committed.

**Before a public release:**

- Telegram does **not** provide self-service API hash rotation or revocation.
  If the credentials were exposed (for example in logs, chat, or a previous
  build), contact `recover@telegram.org` or `support@telegram.org` with the
  API ID and leak context. Treat the hash as permanent until Telegram
  responds; do not paste it into a public issue or chat.
- If Telegram issues replacement credentials (or you deliberately register a
  new developer app with a different phone number), update
  `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` in GitHub Actions and in the local
  `~/.config/grabbit/telegram.env`.
- Remove the 2FA test account's Grabbit entry from that account's Telegram
  client: Settings → Devices → Active Sessions (or Privacy & Security →
  Active Sessions), select the Grabbit/macOS session, and terminate it. This
  cannot be done from a different Telegram account.
- Confirm the main account session still works with the rebuilt helper.

## 10. Release checklist

- [ ] `security find-identity -v -p codesigning` shows the Developer ID
      Application identity.
- [ ] All signing/notary/Sparkle/Telegram secrets are configured.
- [ ] `ALLOW_UNSIGNED_RELEASE` is absent or false.
- [ ] `xcodebuild test` and both Debug/Release builds pass locally.
- [ ] `scripts/vendor-telegram-helper.sh` was run before the release build.
- [ ] Exposed Telegram API credentials resolved with Telegram support (or replacement credentials issued); test device removed from the test account.
- [ ] Tag and push:

  ```sh
  git tag vX.Y.Z
  git push origin vX.Y.Z
  ```

- [ ] After the workflow, verify the downloaded DMG:

  ```sh
  spctl --assess --type open --context context:primary-signature -v \
    Grabbit-vX.Y.Z.dmg
  xcrun stapler validate Grabbit-vX.Y.Z.dmg
  ```
