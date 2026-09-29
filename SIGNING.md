# Code Signing & Notarization Guide

Grabbit is ready for Developer ID signing. Follow these steps on your Mac.

## 1. Apple Developer Program

- Enroll at https://developer.apple.com/programs/ ($99/year).
- This is required for Developer ID signing (outside the App Store).

## 2. Create Developer ID Certificate

1. Open **Keychain Access** → **Certificate Assistant** → **Request a Certificate From a Certificate Authority**.
2. Save the `.certSigningRequest` file.
3. Go to https://developer.apple.com/account/resources/certificates/
4. Click **+** → **Developer ID Application** → upload the request → download the `.cer`.
5. Double-click the `.cer` to install in Keychain.

## 3. Configure Xcode Project

In `project.yml`, under the Grabbit target, set:

```yaml
settings:
  CODE_SIGN_STYLE: Manual
  CODE_SIGN_IDENTITY: "Developer ID Application: Your Name (TEAMID)"
  DEVELOPMENT_TEAM: "TEAMID"
```

Then run `xcodegen generate`.

## 4. Notarization

Apple requires notarization for Developer ID apps. Create an app-specific password:

1. Go to https://appleid.apple.com → **App-Specific Passwords** → Generate.
2. Save it securely.

Add to the release workflow (`.github/workflows/release.yml`) as secrets:
- `APPLE_ID`: your Apple ID email
- `APPLE_APP_PASSWORD`: the app-specific password
- `APPLE_TEAM_ID`: your Team ID

Then add a notarization step after the DMG creation:

```yaml
- name: Notarize DMG
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
    APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
  run: |
    xcrun notarytool submit "dist/Grabbit-${TAG}.dmg" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
    xcrun stapler staple "dist/Grabbit-${TAG}.dmg"
```

## 5. Sparkle Private Key

The EdDSA private key is at `Scripts/release/sparkle-private.pem` (gitignored).

Add it as a GitHub repository secret:
1. Go to https://github.com/sankahchan/grabbit/settings/secrets/actions
2. Click **New repository secret**.
3. Name: `SPARKLE_PRIVATE_KEY`
4. Value: paste the entire contents of `Scripts/release/sparkle-private.pem`.

**Back up this key securely** — if lost, existing installs cannot verify future updates.

## 6. Homebrew Tap

Create a new repo `github.com/sankahchan/homebrew-grabbit`:

```bash
gh repo create sankahchan/homebrew-grabbit --public
```

Copy `homebrew/grabbit.rb` to `Casks/grabbit.rb` in the new repo and push.

Users can then install via:
```bash
brew tap sankahchan/grabbit
brew install --cask grabbit
```

## 7. First Release

Once signing is configured:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Actions workflow will build, sign, notarize, create the DMG,
publish the release, and update `appcast.xml` for Sparkle.
