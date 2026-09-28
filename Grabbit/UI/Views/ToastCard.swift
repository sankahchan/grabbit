import AppKit
import SwiftUI

/// In-app completion/failure card, rendered inline at the top of the
/// Downloads / Torrents tab (inside the tab's own card, not as a floating
/// overlay). Unlike the system notification it carries action buttons
/// (Open File / Open Folder / Try Again) and appears even when Grabbit is
/// frontmost.
struct ToastCard: View {
    let toast: AppToast
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon(for: toast.kind)
                Text(toast.title)
                    .font(.headline)
                Spacer()
                Button {
                    toastCenter.dismiss(id: toast.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Spacer()
                ForEach(actionButtons(for: toast), id: \.title) { action in
                    Button(action.title) { action.handler() }
                        .buttonStyle(NeoButtonStyle(bg: action.bg, compact: true))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        // Bright Neo border accent per kind, readable in both modes.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    toast.kind == .completed ? Neo.green
                        : toast.kind == .failed ? Neo.red : Neo.blue,
                    lineWidth: 3)
        )
    }

    private func statusIcon(for kind: ToastKind) -> some View {
        Group {
            switch kind {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Neo.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Neo.red)
            case .info:
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Neo.blue)
            }
        }
        .font(.title2)
    }

    private struct ToastAction {
        let title: String
        let bg: Color
        let handler: () -> Void
    }

    private func actionButtons(for toast: AppToast) -> [ToastAction] {
        switch toast.kind {
        case .completed:
            var actions: [ToastAction] = []
            // Torrents land in a folder — "Open Folder" only. Direct
            // downloads get both.
            if toast.source == .download, let url = toast.fileURL {
                actions.append(ToastAction(
                    title: NSLocalizedString("toast.openFile", comment: ""),
                    bg: Neo.blue
                ) {
                    NSWorkspace.shared.open(url)
                    toastCenter.dismiss(id: toast.id)
                })
            }
            if let url = toast.fileURL {
                actions.append(ToastAction(
                    title: NSLocalizedString("toast.openFolder", comment: ""),
                    bg: Neo.paper(scheme)
                ) {
                    if toast.source == .download {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                    toastCenter.dismiss(id: toast.id)
                })
            }
            return actions
        case .failed:
            guard let taskID = toast.taskID else { return [] }
            return [ToastAction(
                title: NSLocalizedString("common.retry", comment: ""),
                bg: Neo.green
            ) {
                switch toast.source {
                case .download: engine.resume(taskID)
                case .torrent: torrentEngine.retry(taskID)
                }
                toastCenter.dismiss(id: toast.id)
            }]
        case .info:
            return []
        }
    }
}
