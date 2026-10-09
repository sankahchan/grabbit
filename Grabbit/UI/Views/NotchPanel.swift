import AppKit
import Observation
import SwiftUI

/// The floating "island" at the top-center of the screen (under the notch
/// on notch Macs, under the menu bar everywhere else).
///
/// Primary flow (boring.notch / nochi style): copy a link in the browser,
/// click the pill — it expands into a small action menu with the detected
/// link (magnet / torrent / video / direct) plus pause/resume and
/// open-app actions. Drag & drop still works too. While downloads run the
/// pill shows a progress ring.
@Observable
@MainActor
final class NotchController {
    struct Offer: Equatable {
        let kind: NotchLinkKind
        let label: String
        let icon: String
    }

    enum State: Equatable {
        case idle(Offer?)
        case menu(Offer?)
        case active(progress: Double, speedBytes: Double)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle(nil)
    /// A drag is hovering the pill — brighten the border and grow slightly.
    var isDragHover = false

    private var panel: NSPanel?
    private var timer: Timer?
    private var wasActive = false
    private var transientExpiry: Date?

    private var clipboardOffer: Offer?
    private var lastClipboardChangeCount = 0

    private var settings: SettingsStore?
    private var downloadEngine: DownloadEngine?
    private var torrentEngine: TorrentEngine?
    private var mediaEngine: MediaEngine?
    private var toastCenter: ToastCenter?
    private var navigation: AppNavigation?

    /// NSLog isn't reliably captured for this app, so notch diagnostics go
    /// to a plain file (~/Library/Logs/Grabbit-notch.log).
    private func debugLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Grabbit-notch.log")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

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
        case .idle(let offer):
            NSSize(
                width: (offer == nil ? 170 : 200) + (dragHover ? 12 : 0),
                height: dragHover ? 34 : 30)
        case .menu:
            NSSize(width: 300, height: 134)
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
        watchClipboard()

        // While the menu is open, don't fight the user's interaction.
        if case .menu = state { return }

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
            state = .idle(clipboardOffer)
            transientExpiry = nil
        } else {
            // Keep the idle badge in sync with a freshly copied link.
            state = .idle(clipboardOffer)
        }

        positionPanel(animated: true)
    }

    // MARK: - Clipboard (copy in browser → click the pill)

    private func watchClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: .URL)
        clipboardOffer = Self.offer(from: text)
        if case .idle = state {
            state = .idle(clipboardOffer)
            positionPanel(animated: true)
        }
    }

    static func offer(from text: String?) -> Offer? {
        guard let text else { return nil }
        let kind = NotchLinkClassifier.classify(droppedText: text)
        guard kind != .invalid else { return nil }
        switch kind {
        case .magnet(let magnet):
            return Offer(
                kind: kind,
                label: MagnetParser.displayName(for: magnet) ?? "magnet",
                icon: "arrow.triangle.2.circlepath")
        case .torrentURL(let url):
            return Offer(
                kind: kind, label: url.lastPathComponent,
                icon: "arrow.triangle.2.circlepath")
        case .torrentFile(let url):
            return Offer(
                kind: kind, label: url.lastPathComponent,
                icon: "arrow.triangle.2.circlepath")
        case .mediaPage(let url, _):
            return Offer(
                kind: kind, label: url.host ?? "media",
                icon: "play.rectangle")
        case .direct(let url):
            return Offer(
                kind: kind,
                label: url.lastPathComponent.isEmpty
                    ? (url.host ?? "file")
                    : url.lastPathComponent,
                icon: "doc.fill")
        case .invalid:
            return nil
        }
    }

    // MARK: - Tap (open/close the action menu)

    func handleTap() {
        if case .menu = state {
            debugLog("handleTap: closing menu")
            collapse()
            return
        }
        debugLog("handleTap: opening menu (offer=\(String(describing: clipboardOffer)))")
        state = .menu(clipboardOffer)
        positionPanel(animated: true)
    }

    func collapse() {
        state = .idle(clipboardOffer)
        positionPanel(animated: true)
    }

    func addFromClipboard() {
        guard let offer = clipboardOffer else {
            collapse()
            return
        }
        // Consume: same clipboard contents won't re-offer until something
        // new is copied.
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        clipboardOffer = nil
        route(offer.kind)
        collapse()
    }

    func pauseAll() {
        downloadEngine?.pauseAll()
        torrentEngine?.pauseAll()
        collapse()
    }

    func resumeAll() {
        downloadEngine?.startAllEligible()
        torrentEngine?.resumeAllEligible()
        collapse()
    }

    func openApp() {
        let target = activeSection()
        debugLog("openApp: target=\(target.rawValue) current=\(navigation?.selection.rawValue ?? "nil")")
        navigation?.selection = target
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        collapse()
    }

    /// Where the user should land: the tab that's actually doing work.
    private func activeSection() -> SidebarSelection {
        let torrents = torrentEngine?.torrents.filter {
            $0.state == .downloading || $0.state == .seeding
        }.count ?? 0
        let media = mediaEngine?.state
        debugLog("activeSection: torrents=\(torrents) media=\(String(describing: media))")
        if torrents > 0 {
            return .torrents
        }
        if let media, media == .downloading || media == .probing {
            return .media
        }
        return .downloads
    }

    /// Any download running right now (for the pause/resume row label).
    var isBusy: Bool {
        let downloads = downloadEngine?.items.contains {
            $0.state == .downloading
        } ?? false
        let torrents = torrentEngine?.torrents.contains {
            $0.state == .downloading || $0.state == .seeding
        } ?? false
        return downloads || torrents
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
        debugLog("route: \(kind)")
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
            // yt-dlp is serial: if a media download is already running,
            // just take the user there instead of starting a second one.
            if media?.state == .downloading || media?.state == .probing {
                return
            }
            let directory = settings.folderURL(for: .video)
            Task { @MainActor in
                // downloadStream probes, picks the "Best" preset (first
                // available as fallback) and starts immediately.
                media?.speedLimitBytesPerSec =
                    settings.settings.speedLimitBytesPerSec
                await media?.downloadStream(
                    url: url,
                    to: directory,
                    headers: [:],
                    preferredName: nil)
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
        Group {
            if case .menu = state {
                menuBody(state)
            } else {
                // The whole pill is one real button in every non-menu state
                // — no parent tap gesture that could swallow menu rows.
                Button {
                    controller.handleTap()
                } label: {
                    capsule(for: state)
                }
                .buttonStyle(.plain)
            }
        }
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

    /// Menu: rows stay clickable (they sit on top); tapping anywhere else
    /// collapses via the full-size clear button underneath.
    @ViewBuilder
    private func menuBody(_ state: NotchController.State) -> some View {
        ZStack {
            Button {
                controller.collapse()
            } label: {
                Color.clear
            }
            .buttonStyle(.plain)
            capsule(for: state)
        }
        .frame(width: size(for: state).width, height: size(for: state).height)
    }

    private func capsule(for state: NotchController.State) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: 0x101318).opacity(0.95))
                .allowsHitTesting(false)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(border(for: state), lineWidth: 1.5)
                        .allowsHitTesting(false))
            content(for: state)
        }
        .frame(width: size(for: state).width, height: size(for: state).height)
    }

    @ViewBuilder
    private func content(for state: NotchController.State) -> some View {
        switch state {
        case .idle(let offer):
            HStack(spacing: 7) {
                MochiView(
                    mood: offer == nil ? .idle : .excited,
                    size: 16)
                Text("Grabbit")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                if let offer {
                    Image(systemName: offer.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(Neo.blue)
                    Text(NSLocalizedString("notch.pill.add", comment: ""))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text(NSLocalizedString("notch.pill.click", comment: ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

        case .menu(let offer):
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    MochiView(mood: offer == nil ? .idle : .excited, size: 20)
                    Spacer()
                }
                .padding(.top, 4)
                if let offer {
                    row(icon: offer.icon, color: Neo.blue, label: offer.label) {
                        controller.addFromClipboard()
                    }
                    Divider().overlay(Color.white.opacity(0.10))
                } else {
                    Text(NSLocalizedString("notch.menu.noLink", comment: ""))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.vertical, 10)
                    Divider().overlay(Color.white.opacity(0.10))
                }
                row(
                    icon: controller.isBusy ? "pause.fill" : "play.fill",
                    color: controller.isBusy ? Neo.yellow : Neo.green,
                    label: NSLocalizedString(
                        controller.isBusy
                            ? "notch.menu.pauseAll"
                            : "notch.menu.resumeAll", comment: "")) {
                    if controller.isBusy {
                        controller.pauseAll()
                    } else {
                        controller.resumeAll()
                    }
                }
                Divider().overlay(Color.white.opacity(0.10))
                row(icon: "macwindow", color: .white.opacity(0.8),
                    label: NSLocalizedString("notch.menu.open", comment: "")) {
                    controller.openApp()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

        case .active(let progress, let speed):
            HStack(spacing: 10) {
                MochiView(mood: .working(progress), size: 24)
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
                Spacer()
                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)

        case .done:
            HStack(spacing: 7) {
                MochiView(mood: .done, size: 18)
                Text(NSLocalizedString("notch.done", comment: ""))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
            }

        case .failed(let name):
            HStack(spacing: 7) {
                MochiView(mood: .sad, size: 18)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func row(
        icon: String,
        color: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func border(for state: NotchController.State) -> Color {
        if controller.isDragHover { return Neo.yellow }
        switch state {
        case .idle(let offer):
            return offer == nil ? Neo.blue.opacity(0.55) : Neo.yellow.opacity(0.9)
        case .menu:
            return Neo.blue
        case .active:
            return Neo.blue
        case .done:
            return Neo.green
        case .failed:
            return Neo.red
        }
    }

    private func size(for state: NotchController.State) -> CGSize {
        let ns = NotchController.pillSize(
            for: state, dragHover: controller.isDragHover)
        return CGSize(width: ns.width, height: ns.height)
    }
}

// MARK: - Mochi mascot

/// Mochi reactions, driven by the pill state.
enum MochiMood: Equatable {
    case idle
    case excited
    case working(Double)
    case done
    case sad
}

/// A soft cream mochi drawn with plain SwiftUI shapes — no image assets.
/// Idle it breathes and blinks, it bounces with sparkles when a link is
/// ready, chomps while downloads run, celebrates on completion and droops
/// with a teardrop on failure.
struct MochiView: View {
    var mood: MochiMood = .idle
    var size: CGFloat = 18

    @State private var breathe = false
    @State private var hop = false

    private var isWorking: Bool {
        if case .working = mood { return true }
        return false
    }

    private var isExcited: Bool {
        mood == .excited || (isWorking && controllerHops)
    }

    private var controllerHops: Bool { false }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                bodyShape
                face(t: t)
            }
            .frame(width: size, height: size)
        }
        .scaleEffect(
            y: mood == .sad
                ? 0.82
                : (mood == .idle || mood == .done ? (breathe ? 1.06 : 0.95) : 1),
            anchor: .bottom)
        .offset(y: hop ? -1.6 : 1.6)
        .rotationEffect(.degrees(isWorking ? (hop ? 4 : -4) : 0))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
            if isExcited || isWorking {
                withAnimation(.easeInOut(duration: 0.30).repeatForever(autoreverses: true)) {
                    hop = true
                }
            }
        }
    }

    private var bodyShape: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xFFF8EF), Color(hex: 0xF5E2D2)],
                    startPoint: .top, endPoint: .bottom))
            .overlay(
                Ellipse()
                    .stroke(.white.opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false))
            .frame(width: size * 0.92, height: size * 0.80)
            .overlay(
                HStack(spacing: size * 0.50) {
                    Circle().fill(Color(hex: 0xFFB3A7).opacity(0.9))
                    Circle().fill(Color(hex: 0xFFB3A7).opacity(0.9))
                }
                .frame(width: size * 0.10, height: size * 0.055)
                .offset(y: size * 0.04)
                .allowsHitTesting(false))
            .overlay(alignment: .topTrailing) {
                if isExcited || isWorking || mood == .done {
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(Neo.yellow)
                        .offset(x: size * 0.22, y: -size * 0.18)
                        .opacity(0.5 + 0.5 * abs(sin(timestamp)))
                        .allowsHitTesting(false)
                }
                if mood == .sad {
                    Ellipse()
                        .fill(Neo.blue.opacity(0.9))
                        .frame(width: size * 0.11, height: size * 0.15)
                        .offset(x: size * 0.28, y: -size * 0.16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var timestamp: Double {
        Date().timeIntervalSinceReferenceDate
    }

    private func face(t: TimeInterval) -> some View {
        VStack(spacing: size * 0.13) {
            HStack(spacing: size * 0.16) {
                eye(blinking: mood == .idle
                    && t.truncatingRemainder(dividingBy: 3.4) > 3.25)
                eye(blinking: mood == .idle
                    && t.truncatingRemainder(dividingBy: 3.4) > 3.25)
            }
            mouth(t: t)
        }
        .offset(y: -size * 0.06)
    }

    private func eye(blinking: Bool) -> some View {
        Capsule()
            .fill(Color(hex: 0x2B2320))
            .frame(
                width: size * 0.075,
                height: size * (blinking ? 0.02 : (isExcited || isWorking ? 0.16 : 0.11)))
    }

    @ViewBuilder
    private func mouth(t: TimeInterval) -> some View {
        switch mood {
        case .working:
            let chomp = t.truncatingRemainder(dividingBy: 0.5) < 0.25
            Ellipse()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * (chomp ? 0.17 : 0.08), height: size * 0.10)
        case .sad:
            arcMouth(frowning: true)
        case .done:
            arcMouth(frowning: false)
        case .idle, .excited:
            Capsule()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * 0.09, height: size * 0.035)
        }
    }

    private func arcMouth(frowning: Bool) -> some View {
        Path { path in
            let width = size * 0.17
            if frowning {
                path.move(to: CGPoint(x: 0, y: size * 0.09))
                path.addQuadCurve(
                    to: CGPoint(x: width, y: size * 0.09),
                    control: CGPoint(x: width / 2, y: 0))
            } else {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addQuadCurve(
                    to: CGPoint(x: width, y: 0),
                    control: CGPoint(x: width / 2, y: size * 0.13))
            }
        }
        .stroke(
            Color(hex: 0x2B2320),
            style: StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round))
        .frame(width: size * 0.17, height: size * 0.15)
    }
}

// MARK: - Drop zone

/// NSView that accepts link/magnet/text drags and reports clicks. Dragging
/// a URL out of a browser delivers `.URL`/`.string`; Finder files deliver
/// `.fileURL`.
struct NotchDropZone: NSViewRepresentable {
    var onDropText: (String) -> Void
    var onDropFile: (URL) -> Void
    var onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        sync(view)
        return view
    }

    func updateNSView(_ nsView: DropCatcherView, context: Context) {
        sync(nsView)
    }

    private func sync(_ view: DropCatcherView) {
        view.onDropText = onDropText
        view.onDropFile = onDropFile
        view.onDragChange = onDragChange
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
