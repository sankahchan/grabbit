import Foundation

/// Release notes for the running build: the tagged commit message is bundled
/// into the app at build time (`ReleaseNotes.txt`), so the "What's New" sheet
/// works offline and always matches the installed version. The same text is
/// embedded in the appcast item so Sparkle's update dialog shows it too.
public enum ReleaseNotes {
    public struct Digest: Equatable {
        /// "v1.5.0: media post-processing, RSS subscriptions, …"
        public var title: String
        public var bullets: [String]
        public var paragraphs: [String]

        public var isEmpty: Bool {
            bullets.isEmpty && paragraphs.isEmpty
        }
    }

    /// Parses a commit-message body: the first non-empty line is the title,
    /// "- " lines are bullets, everything else is a paragraph. The
    /// "N tests / 0 failures." trailer is dropped — it is noise for users.
    public static func parse(_ text: String) -> Digest {
        var title = ""
        var bullets: [String] = []
        var paragraphs: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if title.isEmpty {
                title = line.hasPrefix("Release ")
                    ? String(line.dropFirst("Release ".count))
                    : line
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                bullets.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("-") {
                bullets.append(String(line.dropFirst(1)))
            } else if line.range(of: #"^\d+ tests? /"#, options: .regularExpression) != nil {
                continue
            } else {
                paragraphs.append(line)
            }
        }
        return Digest(title: title, bullets: bullets, paragraphs: paragraphs)
    }

    /// True when the app was updated since the last launch. A nil lastSeen
    /// (fresh install) records the version without showing the sheet.
    public static func shouldPresent(lastSeen: String?, current: String) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        return lastSeen != current
    }

    public static func currentVersion(in bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The notes bundled by the build's post-build script, if any.
    public static func bundledText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
