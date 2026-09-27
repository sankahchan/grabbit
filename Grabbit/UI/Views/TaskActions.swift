import SwiftUI
import AppKit

// MARK: - Neo icon button

/// Small square neo-brutalist icon button (Motrix's per-task button row,
/// Grabbit-styled): 2pt ink border, hard offset block shadow rendered as a
/// plain shape — never `.shadow()`: a zero-blur shadow duplicates the glyph
/// as a solid ghost copy (the "doubled text" bug fixed in MediaView).
struct NeoIconButtonStyle: ButtonStyle {
    var bg: Color
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
            .frame(width: 30, height: 30)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Neo.ink(scheme))
                    .offset(x: 3, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Convenience for `.buttonStyle(NeoIconButtonStyle(bg: bg))`.
    func neoIconButton(bg: Color) -> some View {
        buttonStyle(NeoIconButtonStyle(bg: bg))
    }
}

// MARK: - Task actions

/// Per-task actions rendered as an icon group at the top-right of every task
/// card (Motrix's button-row concept, neo-brutalist styling, SF Symbols
/// only). Pure — unit-tested.
enum TaskAction: Hashable, CaseIterable {
    case pause
    case resume
    case delete
    case openFolder
    case copyLink
    case details

    var systemImage: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "arrow.clockwise"
        case .delete: "trash"
        case .openFolder: "folder"
        case .copyLink: "link"
        case .details: "info.circle"
        }
    }

    var fill: Color {
        switch self {
        case .pause: Neo.yellow
        case .resume: Neo.green
        case .delete: Neo.red
        case .openFolder: Neo.blue
        case .copyLink: Neo.purple
        case .details: Neo.yellow
        }
    }

    /// Tooltip / accessibility label. Static-key lookup (see
    /// DownloadState.localizedName — no interpolation).
    var label: String {
        switch self {
        case .pause: String(localized: "task.action.pause")
        case .resume: String(localized: "task.action.resume")
        case .delete: String(localized: "common.delete")
        case .openFolder: String(localized: "task.action.openFolder")
        case .copyLink: String(localized: "task.action.copyLink")
        case .details: String(localized: "task.action.details")
        }
    }

    /// Which actions a direct download shows. The first button is contextual:
    /// pause while active, resume/retry while stalled, hidden when done.
    static func actions(forDownload state: DownloadState) -> [TaskAction] {
        var actions: [TaskAction] = []
        switch state {
        case .downloading:
            actions.append(.pause)
        case .paused, .interrupted, .queued, .failed:
            actions.append(.resume)
        case .completed:
            break
        }
        actions.append(contentsOf: [.delete, .openFolder, .copyLink, .details])
        return actions
    }

    /// Which actions a torrent shows. `copyLinkAvailable` hides the copy
    /// button when there is nothing to copy (e.g. a .torrent-file add with
    /// no magnet or source URI).
    static func actions(
        forTorrentState state: TorrentState,
        copyLinkAvailable: Bool
    ) -> [TaskAction] {
        var actions: [TaskAction] = []
        switch state {
        case .downloading, .seeding:
            actions.append(.pause)
        case .paused, .failed:
            actions.append(.resume)
        case .completed:
            break
        }
        actions.append(.delete)
        actions.append(.openFolder)
        if copyLinkAvailable { actions.append(.copyLink) }
        actions.append(.details)
        return actions
    }

    /// The link the copy button copies: magnet first, then the original
    /// source URI. Nil when there is nothing to copy.
    static func copyableLink(for item: TorrentItem) -> String? {
        let link = item.magnetURI.isEmpty ? item.sourceURI : item.magnetURI
        return link.isEmpty ? nil : link
    }
}

// MARK: - Action bar

/// Row of square neo icon buttons for one task card.
struct TaskActionBar: View {
    let actions: [TaskAction]
    let onAction: (TaskAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                Button {
                    onAction(action)
                } label: {
                    Image(systemName: action.systemImage)
                }
                .buttonStyle(NeoIconButtonStyle(bg: action.fill))
                .help(action.label)
                .accessibilityLabel(action.label)
            }
        }
    }
}

// MARK: - Finder reveal

/// "Open download folder" behavior: selects the file in Finder when it
/// exists, otherwise opens the containing directory. The decision is pure
/// (unit-tested); only `reveal` touches NSWorkspace.
enum FinderReveal {
    /// Pure: decides what Finder should show.
    static func plan(directory: URL, named: String?) -> (target: URL, select: Bool) {
        if let named, !named.isEmpty {
            let candidate = directory.appendingPathComponent(named)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                return (candidate, true)
            }
        }
        return (directory, false)
    }

    @MainActor
    static func reveal(directory: URL, named: String?) {
        let plan = plan(directory: directory, named: named)
        if plan.select {
            NSWorkspace.shared.activateFileViewerSelecting([plan.target])
        } else {
            NSWorkspace.shared.open(plan.target)
        }
    }
}

// MARK: - Clipboard

enum Clipboard {
    static func copy(_ string: String) {
        guard !string.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Shared badge colors

func badgeColor(for state: DownloadState) -> Color {
    switch state {
    case .queued: Neo.paperLight
    case .downloading: Neo.blue
    case .paused: Neo.yellow
    case .completed: Neo.green
    case .failed: Neo.red
    case .interrupted: Neo.orange
    }
}

func badgeColor(for display: TorrentDisplayStatus) -> Color {
    switch display {
    case .downloading: Neo.blue
    case .waitingForMetadata: Neo.yellow
    case .connecting: Neo.blue
    case .seeding: Neo.green
    case .paused: Neo.yellow
    case .completed: Neo.green
    case .failed: Neo.red
    }
}
