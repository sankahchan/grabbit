import Foundation

/// Downloads the latest browser-extension package straight from the GitHub
/// release and installs it over the unpacked copy Chrome/Edge/Brave loads.
/// The user never visits GitHub — one click in the Grabber tab and a Reload
/// in the browser is all that is left.
enum ExtensionUpdater {
    /// Version-less alias asset; always the newest build.
    static let latestZipURL = URL(
        string: "https://github.com/sankahchan/grabbit/releases/latest/download/grabbit-extension-latest.zip")!

    /// Extension IDs the native host accepts (unpacked dev build and the
    /// former Chrome Web Store item).
    static let extensionIDs = [
        "hdgandihmchcpeejohadokljdeicdhig",
        "ccimhjbjoidahibcijllkgoljnonhg",
    ]

    struct InstalledCopy: Equatable {
        var browser: String
        var folder: URL
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case unzip(String)
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .network(let message): return message
            case .unzip(let message): return message
            case .invalidPackage:
                return NSLocalizedString("grabber.extension.invalid", comment: "")
            }
        }
    }

    // MARK: - Finding unpacked copies

    /// Chromium-family profile roots on macOS.
    static var browserRoots: [(name: String, root: URL)] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            ("Chrome", "Google/Chrome"),
            ("Chromium", "Chromium"),
            ("Edge", "Microsoft Edge"),
            ("Brave", "BraveSoftware/Brave-Browser"),
        ].map { (name, relative) in
            (name, base.appendingPathComponent(relative, isDirectory: true))
        }
    }

    /// Unpacked folders recorded in browser preferences for our IDs.
    /// Unpacked entries have `location == 4` and an absolute `path`.
    static func findUnpackedCopies() -> [InstalledCopy] {
        var results: [InstalledCopy] = []
        let fileManager = FileManager.default
        for browser in browserRoots {
            guard let profileDirs = try? fileManager.contentsOfDirectory(
                at: browser.root, includingPropertiesForKeys: nil)
            else { continue }
            for profile in profileDirs {
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") else { continue }
                for preferencesName in ["Secure Preferences", "Preferences"] {
                    let url = profile.appendingPathComponent(preferencesName)
                    guard let data = try? Data(contentsOf: url),
                          let object = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any]
                    else { continue }
                    for path in unpackedPaths(inPreferences: object) {
                        let folder = URL(fileURLWithPath: path)
                        guard !results.contains(where: { $0.folder == folder }),
                              fileManager.fileExists(atPath:
                                folder.appendingPathComponent("manifest.json").path)
                        else { continue }
                        results.append(InstalledCopy(browser: browser.name, folder: folder))
                    }
                }
            }
        }
        return results
    }

    /// Pure parser for the preferences JSON: only our IDs, only unpacked
    /// (location 4) entries with a non-empty path.
    static func unpackedPaths(inPreferences preferences: [String: Any]) -> [String] {
        guard let extensions = preferences["extensions"] as? [String: Any],
              let settings = extensions["settings"] as? [String: Any]
        else { return [] }
        var paths: [String] = []
        for (id, value) in settings {
            guard extensionIDs.contains(id),
                  let entry = value as? [String: Any],
                  let location = entry["location"] as? Int, location == 4,
                  let path = entry["path"] as? String, !path.isEmpty
            else { continue }
            paths.append(path)
        }
        return paths
    }

    // MARK: - Downloading

    /// Downloads the latest extension ZIP to a local file and returns it.
    @discardableResult
    static func downloadLatest(to directory: URL? = nil) async throws -> URL {
        var request = URLRequest(url: latestZipURL)
        request.setValue("Grabbit", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            throw UpdateError.network(
                "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        let directory = directory ?? FileManager.default.temporaryDirectory
        let destination = directory.appendingPathComponent("grabbit-extension-latest.zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: - Installing

    /// Unzips `zip` and mirrors the contents into `folder` (stale files from
    /// the old version are removed). Returns the number of files copied.
    @discardableResult
    static func install(zip: URL, into folder: URL) throws -> Int {
        let staging = zip.deletingLastPathComponent()
            .appendingPathComponent("grabbit-extension-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("manifest.json").path)
        else { throw UpdateError.invalidPackage }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try mirror(from: staging, to: folder)
    }

    /// Two-way relative-path sync: every source file is copied over, and
    /// destination files that no longer exist in the source are removed.
    /// Recursive instead of path-prefix math — enumerator URLs can come
    /// back through /private/var while the base path stays /var, which
    /// breaks string arithmetic on macOS.
    @discardableResult
    static func mirror(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        var relativeFiles = Set<String>()
        var copied = 0

        func copyTree(_ dir: URL, into target: URL, prefix: String) throws {
            let entries = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            for entry in entries {
                let name = entry.lastPathComponent
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                let destinationEntry = target.appendingPathComponent(name)
                if values.isDirectory == true {
                    try fileManager.createDirectory(
                        at: destinationEntry, withIntermediateDirectories: true)
                    try copyTree(entry, into: destinationEntry, prefix: relative)
                } else {
                    relativeFiles.insert(relative)
                    try? fileManager.removeItem(at: destinationEntry)
                    try fileManager.copyItem(at: entry, to: destinationEntry)
                    copied += 1
                }
            }
        }

        func pruneTree(_ dir: URL, prefix: String) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    pruneTree(entry, prefix: relative)
                    if let remaining = try? fileManager.contentsOfDirectory(atPath: entry.path),
                       remaining.isEmpty
                    {
                        try? fileManager.removeItem(at: entry)
                    }
                } else if !relativeFiles.contains(relative) {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }

        try copyTree(source, into: destination, prefix: "")
        pruneTree(destination, prefix: "")
        return copied
    }

    /// Fresh install (no unpacked copy yet): saves the ZIP and an unzipped
    /// folder under ~/Downloads/Grabbit so the user only has to Load unpacked.
    static func saveForManualInstall(zip: URL) throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Grabbit", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let zipDestination = base.appendingPathComponent("grabbit-extension-latest.zip")
        try? fileManager.removeItem(at: zipDestination)
        try fileManager.copyItem(at: zip, to: zipDestination)

        let folder = base.appendingPathComponent("GrabbitExtension", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard fileManager.fileExists(
            atPath: folder.appendingPathComponent("manifest.json").path)
        else { throw UpdateError.invalidPackage }
        return base
    }

    /// Opens `chrome://extensions` in the first installed Chromium-family
    /// browser. Best-effort: Chrome does not register the scheme, so the URL
    /// is handed to the app as a launch argument.
    @discardableResult
    static func openExtensionsPage() -> Bool {
        let bundleIDs = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "org.chromium.Chromium",
        ]
        for bundleID in bundleIDs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", bundleID, "chrome://extensions"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.unzip(detail.isEmpty ? "unzip failed" : detail)
        }
    }
}
