import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Torrents tab: daemon status, one neo card per torrent with progress,
/// speeds, seeds/peers/ratio, per-item pause/resume/remove, file selection,
/// and seeding limits. Driven by the aria2-next daemon via `TorrentEngine`.
struct TorrentsView: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter
    @Environment(\.colorScheme) private var scheme

    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var removingItem: TorrentItem?
    @State private var detailsSubject: TaskDetailsSheet.Subject?

    var body: some View {
        VStack(spacing: 12) {
            NeoPageHeader(
                sticker: NSLocalizedString("page.torrents.sticker", comment: ""),
                title: NSLocalizedString("torrents.title", comment: ""),
                accent: Neo.purple)
            statusCard

            if torrentEngine.vpnHolding {
                vpnWarningCard
            }

            // Completion/failure cards live inside the Torrents card —
            // not as a floating overlay.
            ForEach(toastCenter.toasts.filter { $0.source == .torrent }) { toast in
                ToastCard(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .animation(
                .spring(response: 0.35),
                value: toastCenter.toasts.map(\.id))

            if torrentEngine.torrents.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("torrents.search", comment: "")) {
                        showingSearch = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
                    Button(NSLocalizedString("torrents.add", comment: "")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(torrentEngine.torrents) { item in
                            torrentCard(for: item)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(16)
        .navigationTitle(NSLocalizedString("torrents.title", comment: ""))
        .task {
            // Lazily boot the daemon when the tab first appears.
            try? await torrentEngine.ensureStarted()
        }
        .sheet(isPresented: $showingAdd) {
            TorrentAddSheet()
        }
        .sheet(isPresented: $showingSearch) {
            TorrentSearchSheet()
        }
        .sheet(item: $removingItem) { item in
            TorrentRemoveSheet(item: item)
        }
        .sheet(item: $detailsSubject) { subject in
            TaskDetailsSheet(subject: subject)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(torrentEngine.daemonState.localizedName)
                .font(NeoFont.f(.subheadline, .semibold))
            if case .failed(let message) = torrentEngine.daemonState {
                Text(message)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            switch torrentEngine.daemonState {
            case .failed, .stopped:
                Button(NSLocalizedString("torrents.retry", comment: "")) {
                    Task { try? await torrentEngine.ensureStarted() }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            case .starting, .running, .suspendedVPN:
                EmptyView()
            }
        }
        .neoCard(accent: statusColor)
    }

    private var statusColor: Color {
        switch torrentEngine.daemonState {
        case .running: Neo.green
        case .starting: Neo.yellow
        case .stopped: Neo.paper(scheme)
        case .suspendedVPN: Neo.orange
        case .failed: Neo.red
        }
    }

    private var vpnWarningCard: some View {
        HStack(spacing: 10) {
            AppIcon("exclamationmark.shield.fill", size: 13)
            Text(NSLocalizedString("torrents.vpn.suspended", comment: ""))
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
        }
        // Solid fill + onAccent: the old translucent fill composited to a
        // dark tone with dark text on it (unreadable).
        .foregroundStyle(Neo.onAccent(Neo.red, scheme: scheme))
        .neoCard(bg: Neo.red)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            AppIcon("magnet", size: 44)
                .font(NeoFont.f(52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("torrents.empty", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button(NSLocalizedString("torrents.search", comment: "")) {
                    showingSearch = true
                }
                .neoButton(bg: Neo.purple)
                Button(NSLocalizedString("torrents.add", comment: "")) {
                    showingAdd = true
                }
                .neoButton(bg: Neo.yellow)
            }
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Torrent card

    private func torrentCard(for item: TorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(NeoFont.f(.headline, .bold))
                    .lineLimit(1)
                let display = TorrentDisplayStatus.of(item)
                Text(display.localizedName)
                    .neoBadge(bg: badgeColor(for: display))
                Spacer()
                TaskActionBar(
                    actions: TaskAction.actions(
                        forTorrentState: item.state,
                        copyLinkAvailable: TaskAction.copyableLink(for: item) != nil)
                ) { action in
                    handleAction(action, for: item)
                }
            }

            NeoLinearBar(progress: item.progress, fill: Neo.purple)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(swarmHealthColor(seeders: item.numSeeders))
                        .frame(width: 8, height: 8)
                    Text("\(NSLocalizedString("torrents.seeds", comment: "")): \(item.numSeeders)")
                }
                .help(NSLocalizedString(
                    SwarmHealth.of(seeders: item.numSeeders).helpKey, comment: ""))
                Text("\(NSLocalizedString("torrents.peers", comment: "")): \(item.peers)")
                Text("\(NSLocalizedString("torrents.ratio", comment: "")): \(String(format: "%.2f", item.ratio))")
                Spacer()
                Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
            }
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("↓ \(formatBytes(item.downloadSpeed))/s")
                Text("↑ \(formatBytes(item.uploadSpeed))/s")
                Spacer()
                if let error = item.errorMessage {
                    Text(error)
                        .foregroundStyle(Neo.red)
                        .lineLimit(1)
                }
            }
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)
        }
        .neoCard(accent: Neo.purple)
    }

    private func handleAction(_ action: TaskAction, for item: TorrentItem) {
        switch action {
        case .pause:
            torrentEngine.pause(item.id)
        case .resume:
            if item.state == .failed {
                torrentEngine.retry(item.id)
            } else {
                torrentEngine.resume(item.id)
            }
        case .delete:
            // Confirmation + "delete downloaded data" option.
            removingItem = item
        case .openFolder:
            FinderReveal.reveal(directory: item.savePath, named: item.name)
        case .copyLink:
            if let link = TaskAction.copyableLink(for: item) {
                Clipboard.copy(link)
            }
        case .details:
            detailsSubject = .torrent(item)
        }
    }

    /// Swarm health dot color: green = healthy (5+ seeders),
    /// orange = fair (1-4), red = poor (none).
    private func swarmHealthColor(seeders: Int) -> Color {
        switch SwarmHealth.of(seeders: seeders) {
        case .healthy: Neo.green
        case .fair: Neo.orange
        case .poor: Neo.red
        }
    }
}

// MARK: - Daemon state label

private extension TorrentEngine.DaemonState {
    var localizedName: String {
        switch self {
        case .stopped: NSLocalizedString("torrents.daemon.stopped", comment: "")
        case .starting: NSLocalizedString("torrents.daemon.starting", comment: "")
        case .running: NSLocalizedString("torrents.daemon.running", comment: "")
        case .suspendedVPN: NSLocalizedString("torrents.daemon.suspended", comment: "")
        case .failed: NSLocalizedString("torrents.daemon.failed", comment: "")
        }
    }
}

// MARK: - Add torrent sheet

struct TorrentAddSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(SettingsStore.self) private var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0 // 0 = link, 1 = file
    @State private var input = ""
    @State private var torrentData: Data?
    @State private var torrentName: String?
    @State private var rename = ""
    @State private var destinationOverride: URL?
    @State private var showingPicker = false
    @State private var errorMessage: String?
    @State private var adding = false
    @State private var taskProxy = TaskProxy()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("torrents.add", comment: ""))
                .font(NeoFont.f(.title2, .heavy))

            NeoSegmented(selection: $mode, titles: [
                (0, NSLocalizedString("torrents.add.linkTab", comment: "")),
                (1, NSLocalizedString("torrents.add.fileTab", comment: "")),
            ])

            if mode == 0 {
                HStack(spacing: 8) {
                    TextField(
                        NSLocalizedString("torrents.add", comment: ""),
                        text: $input,
                        prompt: Text(NSLocalizedString("torrents.add.placeholder", comment: ""))
                    )
                    .neoTextField()
                    Button(NSLocalizedString("common.paste", comment: "")) { pasteInput() }
                        .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                }
            } else {
                Button(NSLocalizedString("torrents.add.chooseFile", comment: "")) {
                    showingPicker = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                if let torrentName {
                    Text(torrentName)
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.red)
            }

            // MARK: Rename (optional)
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("torrents.add.rename", comment: ""))
                    .font(NeoFont.f(.headline))
                TextField(
                    NSLocalizedString("torrents.add.rename", comment: ""),
                    text: $rename,
                    prompt: Text(NSLocalizedString("torrents.add.rename.placeholder", comment: ""))
                )
                .neoTextField()
            }

            // MARK: Save folder (optional override)
            HStack {
                Text(NSLocalizedString("add.destination", comment: ""))
                    .font(NeoFont.f(.headline))
                Spacer()
                Text(destinationURL.path)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(NSLocalizedString("add.destination.choose", comment: "")) {
                    if let url = chooseDirectory(initial: destinationURL) {
                        destinationOverride = url
                    }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            }

            // MARK: Proxy (optional per-task override)
            ExpandableSection(title: NSLocalizedString("taskProxy.title", comment: "")) {
                TaskProxySection(draft: $taskProxy)
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("torrents.add", comment: "")) {
                    addTorrent()
                }
                .neoButton(bg: Neo.green)
                .disabled(!canAdd || adding)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [UTType(filenameExtension: "torrent")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                torrentData = try? Data(contentsOf: url)
                torrentName = url.lastPathComponent
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canAdd: Bool {
        if mode == 0 {
            return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return torrentData != nil
    }

    private func pasteInput() {
        if let s = NSPasteboard.general.string(forType: .string) {
            input = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func addTorrent() {
        adding = true
        errorMessage = nil
        let savePath = destinationURL
        let customName = rename.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = torrentEngine
        let taskProxy = taskProxy.scope == .global ? nil : taskProxy
        Task {
            do {
                if mode == 0 {
                    try await engine.add(
                        magnetOrURL: input.trimmingCharacters(in: .whitespacesAndNewlines),
                        savePath: savePath,
                        displayName: customName.isEmpty ? nil : customName,
                        proxy: taskProxy)
                } else if let data = torrentData {
                    try await engine.addTorrentFile(
                        data, savePath: savePath,
                        name: customName.isEmpty ? torrentName : customName,
                        proxy: taskProxy)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                adding = false
            }
        }
    }

    private var destinationURL: URL {
        destinationOverride ?? settings.folderURL(for: .other)
    }
}

// MARK: - File selection sheet

struct TorrentFilesSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let item: TorrentItem
    @State private var files: [Aria2File]?
    @State private var selected: Set<Int> = []
    @State private var expanded: Set<String> = []
    @State private var errorMessage: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("torrents.files.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            Text(item.name)
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let errorMessage {
                Text(errorMessage)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.red)
            }

            if let files {
                HStack {
                    Button(NSLocalizedString("torrents.files.selectAll", comment: "")) {
                        selected = Set(files.map(\.index))
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                    Button(NSLocalizedString("torrents.files.selectNone", comment: "")) {
                        selected = []
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                    Spacer()
                    Text("\(selected.count) / \(files.count)")
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visible) { item in
                            nodeRow(item.node, depth: item.depth)
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                NeoSpinner(size: 20)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("torrents.files.apply", comment: "")) {
                    apply()
                }
                .neoButton(bg: Neo.green)
                .disabled(files == nil || selected.isEmpty || applying)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            do {
                let fetched = try await torrentEngine.fetchFiles(item.id)
                files = fetched
                selected = Set(fetched.filter { $0.selected }.map { $0.index })
                expanded = Set(
                    TorrentFileTree.allDirectoryIDs(
                        in: TorrentFileTree.build(from: fetched)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Forest roots of the current file list.
    private var roots: [TorrentFileNode] {
        guard let files else { return [] }
        return TorrentFileTree.build(from: files)
    }

    /// Flattened visible rows; avoids a recursive `some View` function,
    /// which makes opaque-type inference fragile across toolchains.
    private var visible: [IndentedNode] {
        TorrentFileTree.visibleNodes(roots: roots, expanded: expanded)
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    /// One row of the tree; directories show an expand chevron plus a
    /// tri-state folder checkbox, files show a normal toggle.
    /// Non-recursive: the sheet renders `visible` (pre-flattened), so the
    /// compiler never has to infer an opaque type through recursion.
    private func nodeRow(_ node: TorrentFileNode, depth: Int) -> some View {
        HStack(spacing: 8) {
            if node.isDirectory {
                Button {
                    toggleExpanded(node.id)
                } label: {
                    AppIcon(expanded.contains(node.id)
                        ? "chevron.down" : "chevron.right")
                        .font(NeoFont.f(.caption))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                folderCheckbox(for: node)
                Text(node.name)
                    .font(NeoFont.f(.subheadline, .semibold))
                    .lineLimit(1)
                Text(formatBytes(node.size))
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
            } else if let index = node.fileIndex {
                Toggle(isOn: binding(for: index)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(NeoFont.f(.subheadline))
                            .lineLimit(1)
                        Text(formatBytes(node.size))
                            .font(NeoFont.f(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(NeoToggleStyle())
            }
        }
        .padding(.leading, CGFloat(depth) * 20)
    }

    /// Tri-state folder checkbox: all / some / none of the files below
    /// are selected. Tapping selects or clears the whole subtree.
    private func folderCheckbox(for node: TorrentFileNode) -> some View {
        let state = TorrentFileTree.selection(of: node, selected: selected)
        let systemName: String
        switch state {
        case .all: systemName = "checkmark.square.fill"
        case .some: systemName = "minus.square.fill"
        case .none: systemName = "square"
        }
        return Button {
            let indices = TorrentFileTree.descendantIndices(of: node)
            if state == .all {
                selected.subtract(indices)
            } else {
                selected.formUnion(indices)
            }
        } label: {
            AppIcon(systemName, size: 20)
                .foregroundStyle(state == .none ? .secondary : Neo.green)
                .font(NeoFont.f(.title3))
        }
        .buttonStyle(.plain)
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(index) },
            set: { isOn in
                if isOn { selected.insert(index) } else { selected.remove(index) }
            })
    }

    private func apply() {
        applying = true
        errorMessage = nil
        Task {
            do {
                try await torrentEngine.setFileSelection(item.id, indices: Array(selected))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }
}

// MARK: - Seeding sheet

struct TorrentSeedingSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let item: TorrentItem
    @State private var ratio: Double
    @State private var timeMinutes: Int
    @State private var errorMessage: String?
    @State private var applying = false

    init(item: TorrentItem) {
        self.item = item
        _ratio = State(initialValue: item.seedRatio ?? -1)
        _timeMinutes = State(initialValue: item.seedTimeMinutes ?? -1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("torrents.seeding.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            Text(item.name)
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            seedingRow(
                title: NSLocalizedString("torrents.seeding.ratio", comment: ""),
                value: ratio < 0
                    ? NSLocalizedString("torrents.seeding.useGlobal", comment: "")
                    : ratio == 0
                        ? NSLocalizedString("torrents.seeding.unlimited", comment: "")
                        : String(format: "%.1f", ratio),
                decrease: { ratio = max(-1, ratio - 0.5) },
                increase: { ratio = min(100, ratio + 0.5) })

            seedingRow(
                title: NSLocalizedString("torrents.seeding.time", comment: ""),
                value: timeMinutes < 0
                    ? NSLocalizedString("torrents.seeding.useGlobal", comment: "")
                    : timeMinutes == 0
                        ? NSLocalizedString("torrents.seeding.unlimited", comment: "")
                        : "\(timeMinutes)",
                decrease: { timeMinutes = max(-1, timeMinutes - 30) },
                increase: { timeMinutes = min(10080, timeMinutes + 30) })

            Text(NSLocalizedString("torrents.seeding.note", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.red)
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("torrents.files.apply", comment: "")) {
                    apply()
                }
                .neoButton(bg: Neo.green)
                .disabled(applying)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func seedingRow(
        title: String,
        value: String,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(NeoFont.f(.subheadline, .semibold))
            Spacer()
            Button { decrease() } label: {
                AppIcon("minus", size: 14)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            Text(value)
                .font(NeoFont.digits(.subheadline))
                .frame(minWidth: 120)
            Button { increase() } label: {
                AppIcon("plus", size: 14)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
    }

    private func apply() {
        applying = true
        errorMessage = nil
        let newRatio: Double? = ratio < 0 ? nil : ratio
        let newTime: Int? = timeMinutes < 0 ? nil : timeMinutes
        Task {
            do {
                try await torrentEngine.setSeeding(item.id, ratio: newRatio, timeMinutes: newTime)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }
}

// MARK: - Remove sheet

struct TorrentRemoveSheet: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let item: TorrentItem
    @State private var deleteData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("torrents.remove.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            Text(item.name)
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Toggle(NSLocalizedString("torrents.remove.deleteData", comment: ""), isOn: $deleteData)
                .toggleStyle(NeoToggleStyle())

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("torrents.remove.remove", comment: "")) {
                    torrentEngine.remove(item.id, deleteData: deleteData)
                    dismiss()
                }
                .neoButton(bg: Neo.red)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
