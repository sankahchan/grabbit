import SwiftUI

/// History tab: unified, persistent log of finished tasks across the three
/// engines (direct downloads, torrents, media). Filterable by category;
/// each row offers open-folder / copy-link / re-download / delete.
struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(DownloadEngine.self) private var downloadEngine
    @Environment(TorrentEngine.self) private var torrentEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.colorScheme) private var scheme

    /// Lets media re-downloads jump to the Media tab (URL is copied; the
    /// Media tab already has a Paste button).
    @Binding var selection: SidebarSelection

    @State private var filter: HistoryKind? = nil
    @State private var showingClearConfirm = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 12) {
            header
            filterChips
            if filtered.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { entry in
                            historyRow(for: entry)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .padding(12)
        .navigationTitle(NSLocalizedString("history.title", comment: ""))
        .alert(
            NSLocalizedString("history.clear.confirm.title", comment: ""),
            isPresented: $showingClearConfirm
        ) {
            Button(NSLocalizedString("history.clear.confirm.delete", comment: ""), role: .destructive) {
                history.clear()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("history.clear.confirm.message", comment: ""))
        }
    }

    private var filtered: [HistoryEntry] {
        history.entries(for: filter)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(NSLocalizedString("history.title", comment: ""))
                .font(.title2.weight(.heavy))
            Spacer()
            if !history.entries.isEmpty {
                Button(NSLocalizedString("history.clear", comment: "")) {
                    showingClearConfirm = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
            }
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        HStack(spacing: 8) {
            filterChip(label: NSLocalizedString("history.filter.all", comment: ""),
                       count: history.count(for: nil),
                       selected: filter == nil) {
                filter = nil
            }
            ForEach(HistoryKind.allCases, id: \.self) { kind in
                filterChip(label: kind.filterLabel,
                           count: history.count(for: kind),
                           selected: filter == kind) {
                    filter = kind
                }
            }
            Spacer()
        }
    }

    private func filterChip(
        label: String, count: Int, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.bold))
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .stroke(Neo.ink(scheme), lineWidth: 1.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .foregroundStyle(Neo.onAccent(selected ? Neo.yellow : Neo.paper(scheme), scheme: scheme))
        .background(selected ? Neo.yellow : Neo.paper(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: 2))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 3, y: 3))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("history.empty.title", comment: ""))
                .font(.title2.weight(.heavy))
            Text(NSLocalizedString("history.empty.hint", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Rows

    private func historyRow(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: entry.kind.systemImage)
                    .font(.title3.weight(.bold))
                    .frame(width: 28)
                Text(entry.name)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Spacer()
                Text(entry.status.localizedName)
                    .neoBadge(bg: entry.status == .completed ? Neo.green : Neo.red)
            }

            HStack(spacing: 6) {
                if let total = entry.totalBytes {
                    Text(formatBytes(total))
                }
                Text("•")
                Text(entry.sourceHost)
                    .lineLimit(1)
                Text("•")
                Text(Self.relativeFormatter.localizedString(
                    for: entry.finishedAt, relativeTo: Date()))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if entry.status == .failed,
               let message = entry.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Neo.red)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Spacer()
                rowActions(for: entry)
            }
        }
        .neoCard()
    }

    @ViewBuilder
    private func rowActions(for entry: HistoryEntry) -> some View {
        // Open save folder
        if let dir = saveDirectory(for: entry) {
            Button {
                FinderReveal.reveal(directory: dir, named: saveFilename(for: entry))
            } label: {
                Image(systemName: "folder")
            }
            .neoIconButton(bg: Neo.blue)
            .help(NSLocalizedString("task.action.openFolder", comment: ""))
            .accessibilityLabel(NSLocalizedString("task.action.openFolder", comment: ""))
        }
        // Copy source link
        if !entry.sourceURL.isEmpty {
            Button {
                Clipboard.copy(entry.sourceURL)
            } label: {
                Image(systemName: "link")
            }
            .neoIconButton(bg: Neo.purple)
            .help(NSLocalizedString("task.action.copyLink", comment: ""))
            .accessibilityLabel(NSLocalizedString("task.action.copyLink", comment: ""))
        }
        // Re-download
        if canRedownload(entry) {
            Button {
                redownload(entry)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .neoIconButton(bg: Neo.green)
            .help(NSLocalizedString("history.redownload", comment: ""))
            .accessibilityLabel(NSLocalizedString("history.redownload", comment: ""))
        }
        // Delete entry
        Button {
            history.remove(id: entry.id)
        } label: {
            Image(systemName: "trash")
        }
        .neoIconButton(bg: Neo.red)
        .help(NSLocalizedString("common.delete", comment: ""))
        .accessibilityLabel(NSLocalizedString("common.delete", comment: ""))
    }

    // MARK: - Row helpers (pure)

    /// Directory to reveal: the file's parent when a save path is known,
    /// otherwise the engine's default folder for the kind.
    private func saveDirectory(for entry: HistoryEntry) -> URL? {
        if let path = entry.savePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                return isDir.boolValue ? url : url.deletingLastPathComponent()
            }
            return url.deletingLastPathComponent()
        }
        switch entry.kind {
        case .download: return settings.folderURL(for: .other)
        case .torrent: return settings.folderURL(for: .other)
        case .media: return settings.folderURL(for: .video)
        }
    }

    private func saveFilename(for entry: HistoryEntry) -> String? {
        guard let path = entry.savePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func canRedownload(_ entry: HistoryEntry) -> Bool {
        switch entry.kind {
        case .download:
            return URL(string: entry.sourceURL)?.scheme?.hasPrefix("http") == true
        case .torrent:
            return !entry.sourceURL.isEmpty
        case .media:
            return !entry.sourceURL.isEmpty
        }
    }

    private func redownload(_ entry: HistoryEntry) {
        switch entry.kind {
        case .download:
            guard let url = URL(string: entry.sourceURL) else { return }
            Task { @MainActor in
                await downloadEngine.add(url: url, filename: entry.name)
            }
        case .torrent:
            let dir = settings.folderURL(for: .other)
            Task { @MainActor in
                do {
                    try await torrentEngine.add(
                        magnetOrURL: entry.sourceURL, savePath: dir)
                } catch {
                    // Surface the failure instead of swallowing it —
                    // bad magnets / a down daemon otherwise fail silently.
                    toastCenter.push(AppToast(
                        kind: .failed,
                        source: .torrent,
                        title: NSLocalizedString("toast.failed.title", comment: ""),
                        message: entry.name + " — " + error.localizedDescription,
                        taskID: nil))
                }
            }
        case .media:
            // Media re-download goes through the Media tab's probe flow;
            // copy the URL and jump there — the tab has a Paste button.
            Clipboard.copy(entry.sourceURL)
            selection = .media
        }
    }
}
