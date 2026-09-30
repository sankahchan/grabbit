import SwiftUI
import UniformTypeIdentifiers

/// Downloads tab: recovery banner, then one neo card per download with a
/// segmented per-connection progress bar and pause/resume/cancel/remove.
///
/// The global "+ Add" toolbar button lives in MainView; the empty state here
/// also offers an Add button.
struct DownloadsView: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
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

    var body: some View {
        VStack(spacing: 12) {
            NeoPageHeader(
                sticker: NSLocalizedString("page.downloads.sticker", comment: ""),
                title: NSLocalizedString("downloads.title", comment: ""),
                accent: Neo.yellow)
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
            } else {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("downloads.batch", comment: "")) {
                        showingBatch = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                    Button(NSLocalizedString("downloads.add", comment: "")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(engine.items) { item in
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
    }

    // MARK: - Recovery banner

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Text("\(NSLocalizedString("downloads.recovered.title", comment: "")): \(engine.recoveredCount)")
                .font(.headline.weight(.bold))
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
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("downloads.empty.title", comment: ""))
                .font(.title2.weight(.heavy))
            Text(NSLocalizedString("downloads.empty.hint", comment: ""))
                .font(.subheadline)
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
                    .font(.headline.weight(.bold))
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Neo.red)
                    .lineLimit(2)
            }

            Text(NSLocalizedString("downloads.segments", comment: ""))
                .font(.caption2.weight(.bold))
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
            .font(.caption)
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
