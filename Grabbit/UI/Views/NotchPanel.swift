import AppKit
import Observation
import SwiftUI

/// The floating "island" at the top-center of the screen (under the notch
/// on notch Macs, under the menu bar everywhere else). Drag a link, magnet
/// or .torrent onto it and Grabbit routes it to the right engine; while
/// downloads run it shows a progress ring. Phase B adds the mascot states.
@Observable
@MainActor
final class NotchController {
    enum State: Equatable {
        case idle
        case active(progress: Double, speedBytes: Double)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// A drag is hovering the pill — brighten the border and grow slightly.
    var isDragHover = false

    private var panel: NSPanel?
    private var timer: Timer?
    private var wasActive = false
    private var transientExpiry: Date?

    private weak var settings: SettingsStore?
    private weak var downloadEngine: DownloadEngine?
    private weak var torrentEngine: TorrentEngine?
    private weak var mediaEngine: MediaEngine?
    private weak var toastCenter: ToastCenter?
    private weak var navigation: AppNavigation?

    init() {}

    func configure(
        settings: SettingsStore,
        downloadEngine: DownloadEngine,
        torrentEngine: TorrentEngine,
        mediaEngine: MediaEngine,
        toastCenter: ToastCenter,
        navigation: AppNavigation
    ) {
        self.settings = settings
        self.downloadEngine = downloadEngine
        self.torrentEngine = torrentEngine
        self.mediaEngine = mediaEngine
        self.toastCenter = toastCenter
        self.navigation = navigation
        buildPanel()
        startTimer()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel(animated: false) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let panel else { return }
        if enabled {
            positionPanel(animated: false)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(
            rootView: NotchPillView(controller: self))
        self.panel = panel
        positionPanel(animated: false)
        panel.orderFrontRegardless()
    }

    private func positionPanel(animated: Bool) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let size = Self.pillSize(for: state, dragHover: isDragHover)
        let menuBarHeight = NSStatusBar.system.thickness
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - menuBarHeight - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    static func pillSize(for state: State, dragHover: Bool) -> NSSize {
        switch state {
        case .idle:
            NSSize(width: dragHover ? 190 : 170, height: dragHover ? 34 : 30)
        case .active:
            NSSize(width: 340, height: 48)
        case .done, .failed:
            NSSize(width: 240, height: 34)
        }
    }

    // MARK: - Ticking

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let downloadEngine, let torrentEngine else { return }
        let downloads = downloadEngine.items.filter { $0.state == .downloading }
        let torrents = torrentEngine.torrents.filter { $0.state == .downloading }

        let speed = downloads.reduce(0) { $0 + $1.speedBytesPerSec }
            + torrents.reduce(0) { $0 + Double($1.downloadSpeed) }
        let doneBytes = downloads.reduce(0) { $0 + $1.downloadedBytes }
            + torrents.reduce(0) { $0 + $1.downloadedBytes }
        let totalBytes = downloads.reduce(0) { $0 + ($1.totalBytes ?? 0) }
            + torrents.reduce(0) { $0 + $1.totalBytes }
        let progress = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
        let active = !downloads.isEmpty || !torrents.isEmpty

        if active {
            state = .active(progress: min(1, max(0, progress)), speedBytes: speed)
            wasActive = true
            transientExpiry = nil
        } else if wasActive {
            let failedName = downloadEngine.items.first { $0.state == .failed }?.filename
                ?? torrentEngine.torrents.first { $0.state == .failed }?.name
            if let failedName {
                state = .failed(failedName)
            } else {
                state = .done("")
            }
            transientExpiry = Date().addingTimeInterval(2.5)
            wasActive = false
        } else if let expiry = transientExpiry, Date() > expiry {
            state = .idle
            transientExpiry = nil
        }

        positionPanel(animated: true)
    }

    // MARK: - Drops

    func setDragHover(_ hovering: Bool) {
        guard isDragHover != hovering else { return }
        isDragHover = hovering
        positionPanel(animated: true)
    }

    func handleDrop(text: String) {
        isDragHover = false
        route(NotchLinkClassifier.classify(droppedText: text))
    }

    func handleDrop(fileURL: URL) {
        isDragHover = false
        route(NotchLinkClassifier.classify(droppedFileURL: fileURL))
    }

    private func route(_ kind: NotchLinkKind) {
        guard let settings else { return }
        switch kind {
        case .magnet(let magnet):
            addTorrentSource(magnet)

        case .torrentURL(let url):
            addTorrentSource(url.absoluteString)

        case .torrentFile(let url):
            guard let data = try? Data(contentsOf: url) else {
                showTransientFailure(
                    NSLocalizedString("notch.failed.readFile", comment: ""))
                return
            }
            let engine = torrentEngine
            Task { @MainActor in
                do {
                    try await engine?.addTorrentFile(
                        data,
                        savePath: settings.folderURL(for: .other),
                        name: url.deletingPathExtension().lastPathComponent)
                    toast(.torrent, message: url.lastPathComponent)
                } catch {
                    showTransientFailure(error.localizedDescription)
                }
            }

        case .mediaPage(let url, _):
            navigation?.selection = .media
            NSApp.activate(ignoringOtherApps: true)
            let media = mediaEngine
            Task { @MainActor in
                await media?.probe(url: url, headers: nil)
            }

        case .direct(let url):
            let category = DownloadCategory.infer(
                filename: url.lastPathComponent)
            let engine = downloadEngine
            Task { @MainActor in
                await engine?.add(
                    url: url,
                    category: category,
                    sourceSite: .other,
                    destination: settings.folderURL(for: category))
                toast(.download, message: url.lastPathComponent)
            }

        case .invalid:
            showTransientFailure(
                NSLocalizedString("notch.failed.invalid", comment: ""))
        }
    }

    private func addTorrentSource(_ source: String) {
        guard let settings else { return }
        let name = MagnetParser.displayName(for: source) ?? "torrent"
        let engine = torrentEngine
        Task { @MainActor in
            do {
                try await engine?.add(
                    magnetOrURL: source,
                    savePath: settings.folderURL(for: .other),
                    displayName: name)
                toast(.torrent, message: name)
            } catch {
                showTransientFailure(error.localizedDescription)
            }
        }
    }

    private func toast(_ source: ToastSource, message: String) {
        toastCenter?.push(AppToast(
            kind: .info,
            source: source,
            title: NSLocalizedString("notch.added", comment: ""),
            message: message))
    }

    private func showTransientFailure(_ message: String) {
        state = .failed(message)
        transientExpiry = Date().addingTimeInterval(3)
        positionPanel(animated: true)
    }
}

// MARK: - Pill view

struct NotchPillView: View {
    @Bindable var controller: NotchController

    var body: some View {
        let state = controller.state
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x101318).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(border(for: state), lineWidth: 1.5)
                        .allowsHitTesting(false))
            content(for: state)
        }
        .frame(width: size(for: state).width, height: size(for: state).height)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .background(
            NotchDropZone(
                onDropText: { controller.handleDrop(text: $0) },
                onDropFile: { controller.handleDrop(fileURL: $0) },
                onDragChange: { controller.setDragHover($0) })
        )
        .animation(.easeInOut(duration: 0.18), value: controller.state)
        .animation(.easeInOut(duration: 0.12), value: controller.isDragHover)
    }

    @ViewBuilder
    private func content(for state: NotchController.State) -> some View {
        switch state {
        case .idle:
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Neo.yellow)
                Text("Grabbit")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                Text(NSLocalizedString("notch.pill.hint", comment: ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }

        case .active(let progress, let speed):
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 3.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(
                            Neo.blue,
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("↓ \(formatBytes(Int64(speed)))/s")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Neo.blue)
                }
            }

        case .done:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Neo.green)
                Text(NSLocalizedString("notch.done", comment: ""))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
            }

        case .failed(let name):
            HStack(spacing: 7) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Neo.red)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func border(for state: NotchController.State) -> Color {
        if controller.isDragHover { return Neo.yellow }
        switch state {
        case .idle: return Neo.blue.opacity(0.55)
        case .active: return Neo.blue
        case .done: return Neo.green
        case .failed: return Neo.red
        }
    }

    private func size(for state: NotchController.State) -> CGSize {
        let ns = NotchController.pillSize(
            for: state, dragHover: controller.isDragHover)
        return CGSize(width: ns.width, height: ns.height)
    }
}

// MARK: - Drop zone

/// NSView that accepts link/magnet/text drags. Dragging a URL out of a
/// browser delivers `.URL`/`.string`; Finder files deliver `.fileURL`.
struct NotchDropZone: NSViewRepresentable {
    var onDropText: (String) -> Void
    var onDropFile: (URL) -> Void
    var onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        view.onDropText = onDropText
        view.onDropFile = onDropFile
        view.onDragChange = onDragChange
        return view
    }

    func updateNSView(_ nsView: DropCatcherView, context: Context) {
        nsView.onDropText = onDropText
        nsView.onDropFile = onDropFile
        nsView.onDragChange = onDragChange
    }
}

final class DropCatcherView: NSView {
    var onDropText: ((String) -> Void)?
    var onDropFile: ((URL) -> Void)?
    var onDragChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL, .URL, .string,
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL, .URL, .string,
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let file = files.first {
            onDropFile?(file)
            return true
        }
        if let text = pasteboard.string(forType: .URL)
            ?? pasteboard.string(forType: .string) {
            onDropText?(text)
            return true
        }
        return false
    }
}
