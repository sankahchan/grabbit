# Safari Web Extension Conversion Notes

## Converting the Chrome (MV3) extension to Safari

Run Apple's converter from the repo root:

```bash
xcrun safari-web-extension-converter GrabbitExtension \
  --project-location ./GrabbitExtension-Safari \
  --app-name "Grabbit Web Grabber" \
  --bundle-identifier com.sankahchan.grabbit.extension
```

Then add the generated Safari target(s) to the Grabbit Xcode project
(`Grabbit.xcodeproj`) alongside the main macOS app target.

## Namespace compatibility

- The shared JS (`content.js`, `background.js`) uses the `chrome.*` namespace.
  Safari's Web Extensions support `chrome.*` aliases, but `browser.*` (with
  promises) is the preferred namespace there.
- The code here intentionally uses `chrome.*` **with promise-style calls and
  `.catch()` guards** (e.g. `chrome.runtime.sendMessage(...).catch(...)`,
  `chrome.action.setBadgeText(...).catch(...)`) so it runs in both Chrome and
  Safari without changes. If you prefer, wrap the namespace once:
  `const api = typeof browser !== 'undefined' ? browser : chrome;`
  and use `api.*` throughout.

## Native messaging on Safari

- Safari Web Extensions do **not** support `chrome.runtime.connectNative`.
  The Safari build must talk to the host app differently: use
  `browser.runtime.sendNativeMessage` if available, or (recommended) have the
  Safari app extension communicate with the containing macOS app via the
  standard `SFSafariExtensionHandler` / `NSExtensionContext` bridge, then
  forward payloads to the main Grabbit process (XPC / distributed
  notification / app-group shared file).
- Practically: keep `content.js` detection logic identical; only the
  `sendToApp` transport in `background.js` needs a Safari-specific branch.

## Assets

- `icons/` currently contains only placeholder art (TODO: replace with the
  final Grabbit icon at 16/48/128 px). The converter will warn about missing
  icons — add them before shipping the Safari target.
