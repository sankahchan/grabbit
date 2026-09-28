import Foundation

/// One node of a torrent's file tree. Directories have `fileIndex == nil`
/// and carry children; files are leaves with an aria2 1-based `fileIndex`.
public struct TorrentFileNode: Identifiable {
    public let id: String // path within the torrent, e.g. "sub/clip.mp4"
    public let name: String
    public let size: Int64 // files: length; directories: sum of descendants
    public let fileIndex: Int?
    public var children: [TorrentFileNode]

    public var isDirectory: Bool { fileIndex == nil }
}

public enum FolderSelection: Equatable {
    case all
    case some
    case none
}

/// Swarm health from the seeder count, shown as a colored dot on the
/// torrent card.
public enum SwarmHealth: Equatable {
    case healthy // 5+ seeders
    case fair // 1-4 seeders
    case poor // no seeders

    public static func of(seeders: Int) -> SwarmHealth {
        if seeders >= 5 { return .healthy }
        if seeders >= 1 { return .fair }
        return .poor
    }

    public var helpKey: String {
        switch self {
        case .healthy: "torrents.health.good"
        case .fair: "torrents.health.fair"
        case .poor: "torrents.health.poor"
        }
    }
}

/// Pure file-tree builder over aria2's flat `getFiles` list.
public enum TorrentFileTree {
    /// Builds forest roots from flat files. The common download-dir +
    /// torrent-name prefix collapses away: a single root directory's
    /// children become the roots. Directories sort before files.
    public static func build(from files: [Aria2File]) -> [TorrentFileNode] {
        let root = Builder(name: "", path: "")
        for file in files {
            let components = file.path
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty }
            root.insert(components: components, file: file, prefix: "")
        }
        var nodes = root.children.values.map { $0.node() }.sorted(by: sort)
        // Collapse a lone top-level directory (the torrent's own folder).
        while nodes.count == 1, nodes[0].isDirectory {
            nodes = nodes[0].children.sorted(by: sort)
        }
        return nodes
    }

    /// All aria2 file indices under a node (itself if it's a file).
    public static func descendantIndices(of node: TorrentFileNode) -> [Int] {
        if let index = node.fileIndex { return [index] }
        return node.children.flatMap { descendantIndices(of: $0) }
    }

    /// all/some/none of the node's files are in `selected`.
    public static func selection(
        of node: TorrentFileNode, selected: Set<Int>
    ) -> FolderSelection {
        let indices = descendantIndices(of: node)
        guard !indices.isEmpty else { return .none }
        let hits = indices.filter { selected.contains($0) }.count
        if hits == indices.count { return .all }
        if hits == 0 { return .none }
        return .some
    }

    private static func sort(_ a: TorrentFileNode, _ b: TorrentFileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private final class Builder {
        let name: String
        let path: String
        var children: [String: Builder] = [:]
        var fileIndex: Int?
        var size: Int64 = 0

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func insert(components: [String], file: Aria2File, prefix: String) {
            guard let first = components.first else { return }
            let path = prefix.isEmpty ? first : prefix + "/" + first
            let child = children[first] ?? Builder(name: first, path: path)
            children[first] = child
            if components.count == 1 {
                child.fileIndex = file.index
                child.size = file.length
            } else {
                child.insert(
                    components: Array(components.dropFirst()),
                    file: file, prefix: path)
                child.size += file.length
            }
        }

        func node() -> TorrentFileNode {
            TorrentFileNode(
                id: path,
                name: name,
                size: size,
                fileIndex: fileIndex,
                children: children.values.map { $0.node() })
        }
    }
}
