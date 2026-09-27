import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Torrents tab: daemon status, one neo card per torrent with progress,
/// speeds, seeds/peers/ratio, per-item pause/resume/remove, file selection,
/// and seeding limits. Driven by the aria2-next daemon via `TorrentEngine`.
struct TorrentsView: View {
    @Environment(TorrentEngine.self) private var torrentEngine: TorrentEngine
    @Environment(\.colorScheme) private var scheme

    @State private var showingAdd = false
    @State private var removingItem: TorrentItem?
    @State private var detailsSubject: TaskDetailsSheet.Subject?

    var body: some View {
        VStack(spacing: 12) {
            statusCard

            if torrentEngine.vpnHolding {
                vpnWarningCard
            }

            if torrentEngine.torrents.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                HStack {
                    Spacer()
                    Button(String(localized: "torrents.add")) {
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
        .padding(12)
        .navigationTitle(String(localized: "torrents.title"))
        .task {
            // Lazily boot the daemon when the tab first appears.
            try? await torrentEngine.ensureStarted()
        }
        .sheet(isPresented: $showingAdd) {
            TorrentAddSheet()
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
                .font(.subheadline.weight(.semibold))
            if case .failed(let message) = torrentEngine.daemonState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            switch torrentEngine.daemonState {
            case .failed, .stopped:
                Button(String(localized: "torrents.retry")) {
                    Task { try? await torrentEngine.ensureStarted() }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            case .starting, .running, .suspendedVPN:
                EmptyView()
            }
        }
        .neoCard()
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
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Neo.red)
            Text(String(localized: "torrents.vpn.suspended"))
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .neoCard(bg: Neo.red.opacity(0.15))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnet")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(String(localized: "torrents.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "torrents.add")) {
                showingAdd = true
            }
            .neoButton(bg: Neo.yellow)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Torrent card

    private func torrentCard(for item: TorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(.headline.weight(.bold))
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
                Text("\(String(localized: "torrents.seeds")): \(item.numSeeders)")
                Text("\(String(localized: "torrents.peers")): \(item.peers)")
                Text("\(String(localized: "torrents.ratio")): \(String(format: "%.2f", item.ratio))")
                Spacer()
                Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
            }
            .font(.caption)
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .neoCard()
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
}

// MARK: - Daemon state label

private extension TorrentEngine.DaemonState {
    var localizedName: String {
        switch self {
        case .stopped: String(localized: "torrents.daemon.stopped")
        case .starting: String(localized: "torrents.daemon.starting")
        case .running: String(localized: "torrents.daemon.running")
        case .suspendedVPN: String(localized: "torrents.daemon.suspended")
        case .failed: String(localized: "torrents.daemon.failed")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "torrents.add"))
                .font(.title2.weight(.heavy))

            Picker("", selection: $mode) {
                Text(String(localized: "torrents.add.linkTab")).tag(0)
                Text(String(localized: "torrents.add.fileTab")).tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "torrents.add"),
                        text: $input,
                        prompt: Text(String(localized: "torrents.add.placeholder"))
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(String(localized: "common.paste")) { pasteInput() }
                        .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                }
            } else {
                Button(String(localized: "torrents.add.chooseFile")) {
                    showingPicker = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                if let torrentName {
                    Text(torrentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Neo.red)
            }

            // MARK: Rename (optional)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "torrents.add.rename"))
                    .font(.headline)
                TextField(
                    String(localized: "torrents.add.rename"),
                    text: $rename,
                    prompt: Text(String(localized: "torrents.add.rename.placeholder"))
                )
                .textFieldStyle(.roundedBorder)
            }

            // MARK: Save folder (optional override)
            HStack {
                Text(String(localized: "add.destination"))
                    .font(.headline)
                Spacer()
                Text(destinationURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(String(localized: "add.destination.choose")) {
                    if let url = chooseDirectory(initial: destinationURL) {
                        destinationOverride = url
                    }
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            }

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "torrents.add")) {
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
        Task {
            do {
                if mode == 0 {
                    try await engine.add(
                        magnetOrURL: input.trimmingCharacters(in: .whitespacesAndNewlines),
                        savePath: savePath,
                        displayName: customName.isEmpty ? nil : customName)
                } else if let data = torrentData {
                    try await engine.addTorrentFile(
                        data, savePath: savePath,
                        name: customName.isEmpty ? torrentName : customName)
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
    @State private var errorMessage: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "torrents.files.title"))
                .font(.title2.weight(.heavy))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Neo.red)
            }

            if let files {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(files) { file in
                            Toggle(isOn: binding(for: file.index)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(formatBytes(file.length))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "torrents.files.apply")) {
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
            Text(String(localized: "torrents.seeding.title"))
                .font(.title2.weight(.heavy))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            seedingRow(
                title: String(localized: "torrents.seeding.ratio"),
                value: ratio < 0
                    ? String(localized: "torrents.seeding.useGlobal")
                    : ratio == 0
                        ? String(localized: "torrents.seeding.unlimited")
                        : String(format: "%.1f", ratio),
                decrease: { ratio = max(-1, ratio - 0.5) },
                increase: { ratio = min(100, ratio + 0.5) })

            seedingRow(
                title: String(localized: "torrents.seeding.time"),
                value: timeMinutes < 0
                    ? String(localized: "torrents.seeding.useGlobal")
                    : timeMinutes == 0
                        ? String(localized: "torrents.seeding.unlimited")
                        : "\(timeMinutes)",
                decrease: { timeMinutes = max(-1, timeMinutes - 30) },
                increase: { timeMinutes = min(10080, timeMinutes + 30) })

            Text(String(localized: "torrents.seeding.note"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Neo.red)
            }

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "torrents.files.apply")) {
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
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { decrease() } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            Text(value)
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 120)
            Button { increase() } label: {
                Image(systemName: "plus")
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
            Text(String(localized: "torrents.remove.title"))
                .font(.title2.weight(.heavy))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Toggle(String(localized: "torrents.remove.deleteData"), isOn: $deleteData)

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "torrents.remove.remove")) {
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
