import Foundation

/// Installs (and keeps current) the native-messaging pieces the browser
/// extension needs: the Python helper and the per-browser host manifests.
///
/// The helper ships inside the app bundle, so Sparkle updates refresh it —
/// users never have to re-run `install-host.sh` (which remains as a manual
/// fallback for development checkouts).
enum NativeHostInstaller {
    static let hostName = "com.sankahchan.grabbit"

    /// Unpacked dev builds (the repo manifest carries a stable `key`, so the
    /// ID is the same everywhere) and the Chrome Web Store item may both talk
    /// to the host.
    static let extensionIDs = [
        "hdgandihmchcpeejohadokljdeicdhig",
        "ccimhjbjoidahibcijllkgoljnonhg",
    ]

    static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabbit", isDirectory: true)
    }

    static var helperURL: URL {
        appSupportDirectory.appendingPathComponent("grabbit-native-helper.py")
    }

    /// Chromium-family native-messaging host directories.
    static var browserHostDirectories: [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            "Google/Chrome/NativeMessagingHosts",
            "Chromium/NativeMessagingHosts",
            "Microsoft Edge/NativeMessagingHosts",
            "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { base.appendingPathComponent($0, isDirectory: true) }
    }

    static func manifestObject(
        extensionIDs: [String], helperPath: String
    ) -> [String: Any] {
        [
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
            "description": "Grabbit native messaging host",
            "name": hostName,
            "path": helperPath,
            "type": "stdio",
        ]
    }

    static func manifestData(extensionIDs: [String], helperPath: String) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: manifestObject(
                extensionIDs: extensionIDs, helperPath: helperPath),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Copies the bundled helper into place when its bytes differ. Returns
    /// true when the installed helper was (re)written.
    @discardableResult
    static func installHelper(bundled: URL?, installed: URL) -> Bool {
        guard let bundled,
              let bundledData = try? Data(contentsOf: bundled)
        else { return false }
        if let installedData = try? Data(contentsOf: installed),
           installedData == bundledData
        {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: installed.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try bundledData.write(to: installed, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: installed.path)
            return true
        } catch {
            return false
        }
    }

    /// Writes the host manifest into every browser directory whose copy
    /// differs. Returns the number of manifests written. Best-effort: a
    /// missing browser directory is not an error.
    @discardableResult
    static func installManifests(into directories: [URL], data: Data) -> Int {
        var written = 0
        for dir in directories {
            let target = dir.appendingPathComponent("\(hostName).json")
            if let existing = try? Data(contentsOf: target), existing == data {
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                written += 1
            } catch {
                // Best-effort.
            }
        }
        return written
    }

    /// Launch-time entry point: refresh the helper + manifests. Runs off the
    /// main thread; failures are silent (the extension just stays on the
    /// previous helper until the next launch).
    static func installIfNeeded() {
        let bundled = Bundle.main.url(
            forResource: "grabbit-native-helper", withExtension: "py")
        installHelper(bundled: bundled, installed: helperURL)
        guard let data = manifestData(
            extensionIDs: extensionIDs, helperPath: helperURL.path)
        else { return }
        installManifests(into: browserHostDirectories, data: data)
    }
}
