import Foundation

/// LinkGrabber-style staging (backlog #1, JDownloader-inspired): links land
/// here first for online/offline + size checks and inspect-before-commit,
/// instead of becoming downloads immediately.
///
/// Ideas only — no JDownloader (GPL-3.0) source is used or copied; this is an
/// independent reimplementation for the MIT-licensed Grabbit.
public enum StagedLinkStatus: String, Codable, Sendable {
    /// Probe in flight.
    case checking
    /// Server answered the probe with the file available.
    case online
    /// Server answered with an error, or never answered at all.
    case offline
    /// Already staged, or already a download — listed for inspection but
    /// never committed twice.
    case duplicate
}

/// One link sitting in the staging area.
public struct StagedLink: Identifiable, Codable, Sendable {
    public var id: UUID
    public var url: URL
    /// Editable display name; the probe fills in the server-provided name
    /// only while the user hasn't customized it.
    public var filename: String
    public var filenameCustomized: Bool
    /// Probed size; nil while checking or when the server hides it.
    public var totalBytes: Int64?
    public var status: StagedLinkStatus
    public var packageID: UUID
    public var sourcePageURL: URL?
    public var addedAt: Date
    /// Duplicates start unselected so a blind "commit all" can't double-add.
    public var selected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        filenameCustomized: Bool = false,
        totalBytes: Int64? = nil,
        status: StagedLinkStatus = .checking,
        packageID: UUID,
        sourcePageURL: URL? = nil,
        addedAt: Date = Date(),
        selected: Bool = true
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.filenameCustomized = filenameCustomized
        self.totalBytes = totalBytes
        self.status = status
        self.packageID = packageID
        self.sourcePageURL = sourcePageURL
        self.addedAt = addedAt
        self.selected = selected
    }
}

/// A named bundle of staged links (JDownloader "package").
public struct LinkPackage: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
