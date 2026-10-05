import SwiftUI
import UniformTypeIdentifiers

/// Downloads tab: recovery banner, then one neo card per download with a
/// segmented per-connection progress bar and pause/resume/cancel/remove.
///
/// The global "+ Add" toolbar button lives in MainView; the empty state here
/// also offers an Add button.
struct DownloadsView: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(HistoryStore.self) private var historyStore: HistoryStore
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter
    @Environment(\.colorScheme) private var scheme
    @State private var showingAdd = false
    @State private var showingBatch = false
    /// Snapshot taken when the trash button is clicked. The confirmation
    /// alert must not hold the live `DownloadItem`: the engine mutates it
    /// (bytes/speed) on every tick, which rebuilt the alert ~1×/second and
    /// swallowed the Delete click — users had to click several times.
    @State private var deleteRequest: DeleteRequest?
    @State private var showingDeleteConfirm = false

    private struct DeleteRequest: Identifiable {
        let id: UUID
        let isCompleted: Bool
    }
    @State private var detailsSubject: TaskDetailsSheet.Subject?
    /// Backlog #7: the card currently being dragged (for drop-reorder).
    @State private var draggedItemID: UUID?
    @State private var lastDropTargetID: UUID?
    /// Drag-session generation + torn-drag flag for the deferred
    /// cancel check in the drop delegates (see below).
    @State private var dragGeneration = 0
    @State private var dropExitedWithoutEnter = false
    /// Phase-2 dashboard header: sort, filters, stats.
    @State private var sortOrder: DownloadSortOrder = .added
    @State private var stateFilter: DownloadFilter = .all
    /// Rolling total-speed samples for the stat chart (one per 10s, last 16).
    @State private var speedSamples: [Double] = []

    var body: some View {
        VStack(spacing: 12) {
            header
            if engine.recoveredCount > 0 {
                recoveryBanner
            }
            // Completion/failure cards live inside the Downloads card —
            // not as a floating overlay.
            ForEach(toastCenter.toasts.filter { $0.source == .download }) { toast in
                ToastCard(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .animation(
                .spring(response: 0.35),
                value: toastCenter.toasts.map(\.id))
            if engine.items.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else if displayedItems.isEmpty {
                Spacer()
                searchEmptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(displayedItems) { item in
                            downloadCard(for: item)
                                // Backlog #7: drag a card onto another to
                                // reorder the queue.
                                .onDrag {
                                    engine.beginDragReorder()
                                    dragGeneration += 1
                                    dropExitedWithoutEnter = false
                                    draggedItemID = item.id
                                    lastDropTargetID = nil
                                    return NSItemProvider(
                                        object: item.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: DownloadDropDelegate(
                                    target: item,
                                    draggedID: $draggedItemID,
                                    lastTargetID: $lastDropTargetID,
                                    generation: $dragGeneration,
                                    exitedWithoutEnter: $dropExitedWithoutEnter,
                                    engine: engine))
                        }
                    }
                    .padding(8)
                }
                // Empty list area is a drop target too: releasing a card
                // outside any card reverts the hover preview (see the
                // background delegate) instead of leaving a dirty order.
                .onDrop(of: [.text], delegate: DownloadListBackgroundDropDelegate(
                    draggedID: $draggedItemID,
                    lastTargetID: $lastDropTargetID,
                    generation: $dragGeneration,
                    exitedWithoutEnter: $dropExitedWithoutEnter,
                    engine: engine))
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(16)
        .navigationTitle(NSLocalizedString("downloads.title", comment: ""))
        .sheet(isPresented: $showingAdd) {
            AddDownloadSheet()
        }
        .sheet(isPresented: $showingBatch) {
            BatchAddSheet()
        }
        .alert(
            NSLocalizedString("downloads.remove.title", comment: ""),
            isPresented: $showingDeleteConfirm,
            presenting: deleteRequest
        ) { request in
            // engine.remove drops the record and deletes the partial
            // (.grabbit-part) file; a finished file on disk is kept.
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                engine.remove(request.id)
                deleteRequest = nil
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                deleteRequest = nil
            }
        } message: { request in
            Text(request.isCompleted
                ? NSLocalizedString("downloads.remove.keepFile", comment: "")
                : NSLocalizedString("downloads.remove.deletePartial", comment: ""))
        }
        .sheet(item: $detailsSubject) { subject in
            TaskDetailsSheet(subject: subject)
        }
        .task {
            // Speed history for the "Total speed" stat card.
            while !Task.isCancelled {
                speedSamples.append(totalSpeed)
                if speedSamples.count > 16 {
                    speedSamples.removeFirst(speedSamples.count - 16)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Dashboard header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("page.downloads.sticker", comment: ""))
                        .neoBadge(bg: Neo.yellow)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(NSLocalizedString("downloads.title", comment: ""))
                            .font(NeoFont.f(28, .black))
                            .foregroundStyle(Neo.ink(scheme))
                        Text(summaryLine)
                            .font(NeoFont.f(.caption))
                            .foregroundStyle(Neo.ink2(scheme))
                    }
                }
                Spacer()
                livePill
            }
            statsStrip
            HStack(spacing: 8) {
                filterRow
                Spacer()
                sortMenu
                Button(NSLocalizedString("downloads.batch", comment: "")) {
                    showingBatch = true
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                addButton
                avatarChip
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(DownloadFilter.allCases) { filter in
                let selected = stateFilter == filter
                Button {
                    stateFilter = filter
                } label: {
                    Text(filter.title.uppercased())
                        .font(NeoFont.f(9, .bold))
                        .tracking(0.6)
                        .foregroundStyle(selected ? Neo.blue : Neo.ink2(scheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            selected ? Neo.blue.opacity(0.14) : .clear,
                            in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(
                                    selected
                                        ? Neo.blue.opacity(0.7)
                                        : Neo.ink2(scheme).opacity(0.25),
                                    lineWidth: 1)
                                .allowsHitTesting(false))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(NSLocalizedString("downloads.sort.title", comment: ""), selection: $sortOrder) {
                ForEach(DownloadSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            sortGlyph
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var sortGlyph: some View {
        let bg = Neo.blue
        if Neo.shape.brutalist {
            AppIcon("arrow.up.arrow.down", size: 14)
                .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
                .frame(width: 30, height: 30)
                .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Neo.ink(scheme))
                        .offset(x: 3, y: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Neo.ink(scheme), lineWidth: 2)
                        .allowsHitTesting(false))
        } else if Neo.shape.tileButtons && scheme == .dark {
            AppIcon("arrow.up.arrow.down", size: 14)
                .foregroundStyle(bg)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Neo.card(scheme).opacity(0.72)))
                .background(
                    bg.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(bg.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false))
                .shadow(color: bg.opacity(0.45), radius: 7)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            AppIcon("arrow.up.arrow.down", size: 14)
                .foregroundStyle(bg)
                .frame(width: 30, height: 30)
                .background(bg.opacity(0.14), in: Circle())
                .overlay(
                    Circle()
                        .stroke(bg.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false))
                .contentShape(Circle())
        }
    }

    private var addButton: some View {
        Button {
            showingAdd = true
        } label: {
            HStack(spacing: 6) {
                AppIcon("plus", size: 13)
                Text(NSLocalizedString("downloads.add", comment: ""))
            }
        }
        .buttonStyle(NeoButtonStyle(bg: Neo.yellow))
    }

    private var avatarChip: some View {
        Text("G")
            .font(NeoFont.f(15, .black))
            .foregroundStyle(Neo.green)
            .frame(width: 34, height: 34)
            .background(Neo.card(scheme), in: Circle())
            .overlay(
                Circle()
                    .stroke(Neo.green.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false))
            .help("Grabbit")
    }

    private var livePill: some View {
        let live = liveState
        return HStack(spacing: 5) {
            Circle()
                .fill(live.color)
                .frame(width: 6, height: 6)
                .shadow(color: live.color.opacity(0.8), radius: 3)
            Text("LIVE")
                .font(NeoFont.f(9, .heavy))
                .tracking(1.1)
        }
        .foregroundStyle(live.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(live.color.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(live.color.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false))
        .help(NSLocalizedString(live.helpKey, comment: ""))
    }

    private var statsStrip: some View {
        HStack(spacing: 12) {
            DownloadsStatCard(
                label: NSLocalizedString("downloads.stats.active", comment: ""),
                value: "\(activeCount)",
                unit: nil,
                subtitle: String(
                    format: NSLocalizedString(
                        "downloads.stats.active.addedToday", comment: ""),
                    addedToday),
                accent: Neo.blue,
                chart: MiniBarChart(
                    values: activeProgress,
                    slots: 14,
                    accent: Neo.blue))

            DownloadsStatCard(
                label: NSLocalizedString("downloads.stats.completed", comment: ""),
                value: "\(completedToday)",
                unit: nil,
                subtitle: lastCompletedText,
                accent: Neo.green,
                chart: MiniBarChart(
                    values: completedBuckets,
                    slots: 8,
                    accent: Neo.green))

            DownloadsStatCard(
                label: NSLocalizedString("downloads.stats.speed", comment: ""),
                value: speedDigits.value,
                unit: speedDigits.unit,
                subtitle: speedSubtitle,
                accent: Neo.yellow,
                chart: MiniBarChart(
                    values: speedSamples,
                    slots: 16,
                    accent: Neo.yellow))
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            AppIcon("magnifyingglass", size: 26)
                .font(NeoFont.f(30))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("downloads.search.empty", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Dashboard data

    private var displayedItems: [DownloadItem] {
        var items = engine.items.filter { stateFilter.matches($0) }
        switch sortOrder {
        case .added:
            break // Engine order (queue order).
        case .name:
            items.sort {
                $0.filename.localizedCaseInsensitiveCompare($1.filename)
                    == .orderedAscending
            }
        case .progress:
            items.sort { $0.progress > $1.progress }
        case .size:
            items.sort { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }
        }
        return items
    }

    private var activeItems: [DownloadItem] {
        engine.items.filter { $0.state == .downloading }
    }

    private var activeCount: Int {
        engine.items.filter {
            $0.state == .downloading || $0.state == .queued
        }.count
    }

    private var activeProgress: [Double] {
        activeItems.map(\.progress)
    }

    private var addedToday: Int {
        let calendar = Calendar.current
        return engine.items.filter { calendar.isDateInToday($0.addedAt) }.count
    }

    private var completedToday: Int {
        let calendar = Calendar.current
        return historyStore.entries.filter {
            $0.kind == .download && $0.status == .completed
                && calendar.isDateInToday($0.finishedAt)
        }.count
    }

    /// Completion counts in 3-hour buckets across today (8 bars).
    private var completedBuckets: [Double] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        var buckets = [Double](repeating: 0, count: 8)
        for entry in historyStore.entries
        where entry.kind == .download && entry.status == .completed
            && calendar.isDateInToday(entry.finishedAt)
        {
            let hours = entry.finishedAt.timeIntervalSince(dayStart) / 3600
            buckets[min(7, max(0, Int(hours / 3)))] += 1
        }
        return buckets
    }

    private var lastCompletedText: String {
        let last = historyStore.entries
            .filter { $0.kind == .download && $0.status == .completed }
            .map(\.finishedAt).max()
        guard let last else {
            return NSLocalizedString(
                "downloads.stats.completed.none", comment: "")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return String(
            format: NSLocalizedString(
                "downloads.stats.completed.last", comment: ""),
            formatter.localizedString(for: last, relativeTo: Date()))
    }

    private var totalSpeed: Double {
        activeItems.reduce(0) { $0 + $1.speedBytesPerSec }
    }

    private var summaryLine: String {
        String(
            format: NSLocalizedString("downloads.header.summary", comment: ""),
            activeCount,
            formatBytes(Int64(totalSpeed)) + "/s")
    }

    private var speedDigits: (value: String, unit: String) {
        if totalSpeed >= 1_000_000 {
            return (String(format: "%.1f", totalSpeed / 1_000_000), "MB/s")
        }
        if totalSpeed >= 1_000 {
            return (String(format: "%.0f", totalSpeed / 1_000), "KB/s")
        }
        return ("0", "KB/s")
    }

    private var speedSubtitle: String {
        let samples = speedSamples.filter { $0 > 0 }
        guard !samples.isEmpty else {
            return NSLocalizedString("downloads.stats.speed.live", comment: "")
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        let delta = totalSpeed - average
        guard delta > 1_000 else {
            return NSLocalizedString("downloads.stats.speed.live", comment: "")
        }
        return String(
            format: NSLocalizedString(
                "downloads.stats.speed.overAverage", comment: ""),
            formatBytes(Int64(delta)) + "/s")
    }

    private var liveState: (color: Color, helpKey: String) {
        if activeCount > 0 {
            (Neo.blue, "downloads.live.active")
        } else if engine.items.contains(where: { $0.state == .failed }) {
            (Neo.red, "downloads.live.failed")
        } else if engine.items.contains(where: {
            $0.state == .paused || $0.state == .queued
        }) {
            (Neo.yellow, "downloads.live.paused")
        } else {
            (Neo.ink3(scheme), "downloads.live.idle")
        }
    }

    // MARK: - Recovery banner

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Text("\(NSLocalizedString("downloads.recovered.title", comment: "")): \(engine.recoveredCount)")
                .font(NeoFont.f(.headline, .bold))
            Spacer()
            Button(NSLocalizedString("downloads.resumeAll", comment: "")) {
                engine.resumeAllInterrupted()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            Button(NSLocalizedString("common.close", comment: "")) {
                engine.dismissRecovery()
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
        }
        .foregroundStyle(Neo.onAccent(Neo.yellow, scheme: scheme))
        .neoCard(bg: Neo.yellow)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            AppIcon("tray.and.arrow.down", size: 44)
                .font(NeoFont.f(52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("downloads.empty.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            Text(NSLocalizedString("downloads.empty.hint", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(NSLocalizedString("downloads.batch", comment: "")) {
                    showingBatch = true
                }
                .neoButton(bg: Neo.blue)
                Button(NSLocalizedString("downloads.add", comment: "")) {
                    showingAdd = true
                }
                .neoButton(bg: Neo.yellow)
            }
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Download card

    private func downloadCard(for item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.filename)
                    .font(NeoFont.f(.headline, .bold))
                    .lineLimit(1)
                stateBadge(for: item.state)
                // Backlog #7: per-task priority marker.
                if item.priority != 0 {
                    Text(item.priority > 0
                        ? "↑\(item.priority)" : "↓\(-item.priority)")
                        .neoBadge(bg: item.priority > 0 ? Neo.green : Neo.orange)
                }
                Spacer()
                TaskActionBar(actions: TaskAction.actions(forDownload: item.state)) { action in
                    handleAction(action, for: item)
                }
            }

            HStack(spacing: 6) {
                SourceBadge(site: item.sourceSite)
                Text(item.category.localizedName)
                    .neoBadge(bg: Neo.purple)
            }

            // Surface the failure reason — without this a failed download
            // shows just "FAILED" and nobody knows why (HTTP 403? no range
            // support? connection dropped?).
            if item.state == .failed, let message = item.errorMessage, !message.isEmpty {
                Text(message)
                    .font(NeoFont.f(.caption, .semibold))
                    .foregroundStyle(Neo.red)
                    .lineLimit(2)
            }

            Text(NSLocalizedString("downloads.segments", comment: ""))
                .font(NeoFont.f(.caption2, .bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            SegmentedProgressBar(segments: item.segments)

            HStack {
                Text("\(NSLocalizedString("downloads.speed", comment: "")): \(formatSpeed(item.speedBytesPerSec))")
                Text("•")
                Text("\(NSLocalizedString("downloads.eta", comment: "")): \(formatETA(item.etaSeconds))")
                if item.state == .downloading {
                    Text("•")
                    Text("\(item.segments.count) \(NSLocalizedString("downloads.connections", comment: ""))")
                }
                Spacer()
                Text("\(Int((item.progress * 100).rounded()))%")
                    .fontWeight(.bold)
            }
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)
        }
        .neoCard(accent: badgeColor(for: item.state))
    }

    private func handleAction(_ action: TaskAction, for item: DownloadItem) {
        switch action {
        case .pause:
            engine.pause(item.id)
        case .resume:
            engine.resume(item.id)
        case .delete:
            deleteRequest = DeleteRequest(id: item.id, isCompleted: item.state == .completed)
            showingDeleteConfirm = true
        case .openFolder:
            FinderReveal.reveal(
                directory: item.destinationURL.deletingLastPathComponent(),
                named: item.destinationURL.lastPathComponent)
        case .copyLink:
            Clipboard.copy(item.url.absoluteString)
        case .details:
            detailsSubject = .download(item)
        }
    }

    private func stateBadge(for state: DownloadState) -> some View {
        Text(state.localizedName)
            .neoBadge(bg: badgeColor(for: state))
    }
}

/// Backlog #7: drag-reorder for the downloads list. Reorders live as the
/// dragged card hovers over a target (dropEntered), so the list visibly
/// follows the drag; the ranks are persisted and the queue re-kicked once
/// in performDrop. `lastTargetID` suppresses spurious repeat fires for the
/// same target while the rows animate under a stationary cursor.
///
/// A torn-down drag (Escape, or released over empty space / outside the
/// app) never reaches performDrop, which would leave the in-memory order
/// dirty — hover-reordered but unpersisted, with no commit coming. The
/// engine snapshots the pre-drag order on beginDragReorder; dropExited
/// schedules a deferred check that reverts via cancelDragReorder when no
/// dropEntered followed (a move to another target always enters it in the
/// same event turn, clearing the flag before the check runs).
private struct DownloadDropDelegate: DropDelegate {
    let target: DownloadItem
    @Binding var draggedID: UUID?
    @Binding var lastTargetID: UUID?
    @Binding var generation: Int
    @Binding var exitedWithoutEnter: Bool
    let engine: DownloadEngine

    func dropEntered(info: DropInfo) {
        exitedWithoutEnter = false
        guard let draggedID, draggedID != target.id,
              target.id != lastTargetID
        else { return }
        lastTargetID = target.id
        engine.moveItem(draggedID: draggedID, to: target.id)
    }

    func dropExited(info: DropInfo) {
        scheduleTornDragCheck(
            generation: $generation,
            exitedWithoutEnter: $exitedWithoutEnter,
            draggedID: $draggedID,
            lastTargetID: $lastTargetID,
            engine: engine)
    }

    func performDrop(info: DropInfo) -> Bool {
        engine.commitItemOrder()
        draggedID = nil
        lastTargetID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Drop target for the empty list area: releasing a dragged card outside
/// any card reverts the hover preview instead of leaving it dirty.
private struct DownloadListBackgroundDropDelegate: DropDelegate {
    @Binding var draggedID: UUID?
    @Binding var lastTargetID: UUID?
    @Binding var generation: Int
    @Binding var exitedWithoutEnter: Bool
    let engine: DownloadEngine

    func dropEntered(info: DropInfo) {
        exitedWithoutEnter = false
    }

    func dropExited(info: DropInfo) {
        scheduleTornDragCheck(
            generation: $generation,
            exitedWithoutEnter: $exitedWithoutEnter,
            draggedID: $draggedID,
            lastTargetID: $lastTargetID,
            engine: engine)
    }

    func performDrop(info: DropInfo) -> Bool {
        engine.cancelDragReorder()
        draggedID = nil
        lastTargetID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Deferred torn-drag check shared by the downloads drop delegates.
/// See DownloadDropDelegate for the rationale.
private func scheduleTornDragCheck(
    generation: Binding<Int>,
    exitedWithoutEnter: Binding<Bool>,
    draggedID: Binding<UUID?>,
    lastTargetID: Binding<UUID?>,
    engine: DownloadEngine
) {
    let gen = generation.wrappedValue
    exitedWithoutEnter.wrappedValue = true
    Task { @MainActor in
        // A card-to-card move enters the next target within the same event
        // turn; the delay only needs to outlast that, not the gesture.
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard gen == generation.wrappedValue,
              exitedWithoutEnter.wrappedValue,
              draggedID.wrappedValue != nil
        else { return }
        engine.cancelDragReorder()
        draggedID.wrappedValue = nil
        lastTargetID.wrappedValue = nil
    }
}
