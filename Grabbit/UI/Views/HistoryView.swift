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
            NeoPageHeader(
                sticker: NSLocalizedString("page.history.sticker", comment: ""),
                title: NSLocalizedString("history.title", comment: ""),
                accent: Neo.orange)
            // The window title already reads "History"; the old in-content
            // duplicate is gone. Filter chips carry the CLEAR action.
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
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(16)
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

    // The old in-content "History" title duplicated the window title and has
    // been merged away; CLEAR now sits at the end of the filter row.

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
            if !history.entries.isEmpty {
                Button(NSLocalizedString("history.clear", comment: "")) {
                    showingClearConfirm = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
            }
        }
    }

    private func filterChip(
        label: String, count: Int, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(NeoFont.f(.subheadline, .bold))
                Text("\(count)")
                    .font(NeoFont.f(.caption, .bold))
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
            AppIcon("clock.arrow.circlepath", size: 44)
                .font(NeoFont.f(52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("history.empty.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            Text(NSLocalizedString("history.empty.hint", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Rows

    private func historyRow(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIcon(entry.kind.systemImage, size: 20)
                    .font(NeoFont.f(.title3, .bold))
                    .frame(width: 28)
                Text(entry.name)
                    .font(NeoFont.f(.headline, .bold))
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
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)

            if entry.status == .failed,
               let message = entry.errorMessage, !message.isEmpty {
                Text(message)
                    .font(NeoFont.f(.caption, .semibold))
                    .foregroundStyle(Neo.red)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Spacer()
                rowActions(for: entry)
            }
        }
        .neoCard(accent: entry.status == .failed ? Neo.red : Neo.green)
    }

    @ViewBuilder
    private func rowActions(for entry: HistoryEntry) -> some View {
        // Open save folder
        if let dir = saveDirectory(for: entry) {
            Button {
                FinderReveal.reveal(directory: dir, named: saveFilename(for: entry))
            } label: {
                AppIcon("folder", size: 14)
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
                AppIcon("link", size: 14)
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
                AppIcon("arrow.clockwise", size: 14)
            }
            .neoIconButton(bg: Neo.green)
            .help(NSLocalizedString("history.redownload", comment: ""))
            .accessibilityLabel(NSLocalizedString("history.redownload", comment: ""))
        }
        // Delete entry
        Button {
            history.remove(id: entry.id)
        } label: {
            AppIcon("trash", size: 14)
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
            guard let request = HistoryRetry.request(
                for: entry,
                torrentSaveFolder: settings.folderURL(for: .other)
            ), let url = URL(string: request.sourceURL) else { return }
            Task { @MainActor in
                await downloadEngine.add(url: url, filename: request.name, proxy: request.proxy)
                toastCenter.push(HistoryRetry.startedToast(for: request))
            }
        case .torrent:
            guard let request = HistoryRetry.request(
                for: entry,
                torrentSaveFolder: settings.folderURL(for: .other)
            ) else { return }
            Task { @MainActor in
                do {
                    try await torrentEngine.add(
                        magnetOrURL: request.sourceURL,
                        savePath: request.torrentSaveFolder ?? settings.folderURL(for: .other),
                        proxy: request.proxy)
                    toastCenter.push(HistoryRetry.startedToast(for: request))
                } catch {
                    toastCenter.push(HistoryRetry.failedToast(for: request, error: error))
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
