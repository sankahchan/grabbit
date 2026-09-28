import Foundation

/// Packagizer-style rule (backlog #4, JDownloader idea): when a download
/// URL matches the regex, the file is renamed via the template and/or
/// routed to a category — automatically, at add time.
public struct PackagizerRule: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Regular expression matched against the full URL string.
    public var urlPattern: String
    /// Rename template. Placeholders: {name} (filename without
    /// extension), {ext}, {host}. Empty = keep the server's name.
    public var filenameTemplate: String
    /// nil = auto-detect the category as usual.
    public var category: DownloadCategory?

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        urlPattern: String = "",
        filenameTemplate: String = "",
        category: DownloadCategory? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.urlPattern = urlPattern
        self.filenameTemplate = filenameTemplate
        self.category = category
    }

    /// An invalid regex never matches — a typo'd rule stays inert instead
    /// of crashing or matching everything.
    public func matches(url: URL) -> Bool {
        guard isEnabled, !urlPattern.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else {
            return false
        }
        let target = url.absoluteString
        let range = NSRange(target.startIndex..., in: target)
        return regex.firstMatch(in: target, range: range) != nil
    }

    /// Renders the template for a concrete file. Returns nil when the
    /// template is blank (keep the server's name) or renders blank.
    public func render(filename: String, host: String?) -> String? {
        let template = filenameTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }
        let ns = filename as NSString
        var result = template
        result = result.replacingOccurrences(
            of: "{name}", with: ns.deletingPathExtension)
        result = result.replacingOccurrences(
            of: "{ext}", with: ns.pathExtension)
        result = result.replacingOccurrences(
            of: "{host}", with: host ?? "")
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
