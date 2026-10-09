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
    /// The mouse is over the island (boring.notch-style reveal).
    var isHover = false

    private var panel: NSPanel?
    private var timer: Timer?
    /// Height of the physical notch (0 on non-notch Macs). The island hangs
    /// from the very top edge of the screen; content stays below this inset.
    private(set) var topInset: CGFloat = 0
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

    private var soundCache: [String: NSSound] = [:]
    private var lastSoundAt: [String: Date] = [:]

    /// Tiny macOS system blips for Mochi's moments. Gated by settings and
    /// rate-limited so bursts (many completions at once) stay polite.
    private func playSound(_ name: String) {
        guard settings?.settings.notchSoundsEnabled != false else { return }
        let now = Date()
        if let last = lastSoundAt[name],
           now.timeIntervalSince(last) < 0.4 {
            return
        }
        lastSoundAt[name] = now
        let sound = soundCache[name] ?? NSSound(named: name)
        soundCache[name] = sound
        sound?.stop()
        sound?.play()
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
        panel.hasShadow = false
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
        let inset = screen.safeAreaInsets.top
        if topInset != inset { topInset = inset }
        let size = Self.pillSize(
            for: state, dragHover: isDragHover, hover: isHover,
            topInset: inset)
        // Flush with the screen's top edge — a black tab hanging down from
        // the menu bar, exactly like the notch in boring.notch.
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    static func pillSize(
        for state: State, dragHover: Bool, hover: Bool, topInset: CGFloat
    ) -> NSSize {
        let hasNotch = topInset > 0
        switch state {
        case .idle(let offer):
            if offer != nil || hover || dragHover {
                return NSSize(width: 224, height: topInset + 40)
            }
            // Rest: on notch Macs this is exactly the notch itself
            // (invisible); everywhere else a slim fake-notch tab.
            return NSSize(width: 204, height: hasNotch ? topInset : 36)
        case .menu:
            return NSSize(width: 320, height: topInset + 182)
        case .active:
            return NSSize(width: 320, height: topInset + 56)
        case .done, .failed:
            return NSSize(width: 240, height: topInset + 40)
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
                playSound("Basso")
            } else {
                state = .done("")
                playSound("Glass")
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
        let offer = Self.offer(from: text)
        if let offer, offer != clipboardOffer {
            playSound("Pop")
        }
        clipboardOffer = offer
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
        playSound("Tink")
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

    func setHover(_ hovering: Bool) {
        guard isHover != hovering else { return }
        isHover = hovering
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
        if case .invalid = kind {} else { playSound("Purr") }
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
        .shadow(
            color: .black.opacity(isExpanded(state) ? 0.35 : 0),
            radius: 12, y: 6)
        .background(
            NotchDropZone(
                onHover: { controller.setHover($0) },
                onDropText: { controller.handleDrop(text: $0) },
                onDropFile: { controller.handleDrop(fileURL: $0) },
                onDragChange: { controller.setDragHover($0) })
        )
        .animation(.easeInOut(duration: 0.18), value: controller.state)
        .animation(.easeInOut(duration: 0.12), value: controller.isDragHover)
        .animation(
            .spring(response: 0.30, dampingFraction: 0.72),
            value: controller.isHover)
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

    /// The island hangs from the very top of the screen: square top
    /// corners (flush with the edge), generously rounded bottom corners —
    /// a fake notch when idle, an expanding card when in use.
    private func capsule(for state: NotchController.State) -> some View {
        ZStack {
            tabShape(for: state)
                .fill(Color.black.opacity(0.97))
                .allowsHitTesting(false)
            if controller.isDragHover {
                tabShape(for: state)
                    .stroke(.white.opacity(0.35), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            content(for: state)
                .padding(.top, controller.topInset)
        }
        .frame(width: size(for: state).width, height: size(for: state).height)
        .clipShape(tabShape(for: state))
    }

    private func tabShape(for state: NotchController.State) -> UnevenRoundedRectangle {
        let radius: CGFloat
        switch state {
        case .idle: radius = 12
        case .done, .failed: radius = 14
        case .active: radius = 18
        case .menu: radius = 22
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous)
    }

    private func isExpanded(_ state: NotchController.State) -> Bool {
        if case .idle = state { return false }
        return true
    }

    @ViewBuilder
    private func content(for state: NotchController.State) -> some View {
        switch state {
        case .idle(let offer):
            // On notch Macs the rest state is the bare notch — reveal the
            // content on hover, drag or a pending offer.
            if offer == nil && !controller.isHover && !controller.isDragHover
                && controller.topInset > 0 {
                EmptyView()
            } else {
                idleRow(offer)
            }

        case .menu(let offer):
            menuContent(offer)

        case .active(let progress, let speed):
            activeRow(progress: progress, speed: speed)

        case .done:
            HStack(spacing: 7) {
                MochiView(mood: .done, size: 24)
                Text(NSLocalizedString("notch.done", comment: ""))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
            }

        case .failed(let name):
            HStack(spacing: 7) {
                MochiView(mood: .sad, size: 24)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func idleRow(_ offer: NotchController.Offer?) -> some View {
        HStack(spacing: 7) {
            MochiView(
                mood: offer == nil ? .idle : .excited,
                size: offer == nil ? (controller.isHover ? 26 : 22) : 24,
                lively: controller.isHover)
            if let offer {
                    Image(systemName: offer.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(Neo.blue)
                    Text(NSLocalizedString("notch.pill.add", comment: ""))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
            } else if controller.isHover {
                Text("Grabbit")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                Text(NSLocalizedString("notch.pill.click", comment: ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private func menuContent(_ offer: NotchController.Offer?) -> some View {
        VStack(spacing: 0) {
                HStack {
                    Spacer()
                    MochiView(
                        mood: offer == nil ? .idle : .excited,
                        size: 32, lively: true)
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
        .padding(.top, controller.topInset > 0 ? 10 : 14)
        .padding(.bottom, 6)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func activeRow(progress: Double, speed: Double) -> some View {
        HStack(spacing: 10) {
                MochiView(mood: .working(progress), size: 30, lively: true)
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
            if controller.isHover {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
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

    private func size(for state: NotchController.State) -> CGSize {
        let ns = NotchController.pillSize(
            for: state, dragHover: controller.isDragHover,
            hover: controller.isHover, topInset: controller.topInset)
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
/// It is never truly still: it breathes, looks around, blinks (double
/// blinks when it feels fancy), hops every few seconds, puffs up when the
/// mouse comes close, bounces with sparkles when a link is ready, chomps
/// while downloads run, celebrates on completion and droops on failure.
struct MochiView: View {
    var mood: MochiMood = .idle
    var size: CGFloat = 18
    /// Extra liveliness for hover moments (pops up + sparkles).
    var lively: Bool = false

    @State private var pop = false

    private var isWorking: Bool {
        if case .working = mood { return true }
        return false
    }

    private var isExcited: Bool { mood == .excited }
    private var isIdle: Bool { mood == .idle }
    private var sparkles: Bool {
        isExcited || isWorking || mood == .done || lively
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                bodyShape(t: t)
                face(t: t)
            }
            .frame(width: size, height: size)
            .scaleEffect(
                x: pop ? 1.10 : 1,
                y: (pop ? 1.10 : 1) * breathing(t: t),
                anchor: .bottom)
            .offset(y: bounce(t: t))
            .rotationEffect(.degrees(tilt(t: t)))
        }
        .onChange(of: lively) { _, on in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                pop = on
            }
        }
    }

    // MARK: Motion

    /// Slow breathing, plus a squash-and-stretch hop every ~8 seconds.
    private func breathing(t: TimeInterval) -> CGFloat {
        guard isIdle || mood == .done else { return 1 }
        let breath = 1 + 0.045 * sin(t * 2 * .pi / 2.8)
        let c = t.truncatingRemainder(dividingBy: 8)
        if c > 7.30, c < 7.90 {
            let p = (c - 7.30) / 0.60
            return breath * (1 - 0.16 * sin(p * .pi))
        }
        return breath
    }

    /// Little hops: calm states every ~8s, excited bounces, working bobs.
    private func bounce(t: TimeInterval) -> CGFloat {
        if isExcited { return -2.2 * abs(sin(t * 5)) }
        if isWorking { return -1.6 * abs(sin(t * 7)) }
        if mood == .sad { return 1.2 }
        guard isIdle, !lively else { return 0 }
        let c = t.truncatingRemainder(dividingBy: 8)
        guard c > 7.35, c < 7.85 else { return 0 }
        let p = (c - 7.35) / 0.50
        return -5.5 * sin(p * .pi)
    }

    private func tilt(t: TimeInterval) -> Double {
        if isWorking { return 3.5 * sin(t * 8) }
        if mood == .sad { return -3 }
        return 0
    }

    private func blinking(t: TimeInterval) -> Bool {
        let c = t.truncatingRemainder(dividingBy: 3.6)
        return (c > 3.40 && c < 3.56) || (c > 3.62 && c < 3.74)
    }

    /// The eyes drift slowly side to side — it is watching the world.
    private func lookAround(t: TimeInterval) -> CGFloat {
        size * 0.07 * sin(t * 2 * .pi / 5.4)
    }

    // MARK: Body

    private func bodyShape(t: TimeInterval) -> some View {
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
                if sparkles {
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.24, weight: .bold))
                        .foregroundStyle(Neo.yellow)
                        .offset(x: size * 0.24, y: -size * 0.18)
                        .opacity(0.45 + 0.55 * abs(sin(t * 3)))
                        .scaleEffect(lively ? 1.2 : 1)
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
            .overlay(alignment: .bottomLeading) {
                if isExcited || mood == .done || lively {
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .offset(x: -size * 0.20, y: size * 0.20)
                        .opacity(0.35 + 0.65 * abs(cos(t * 2.6)))
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Face

    private func face(t: TimeInterval) -> some View {
        VStack(spacing: size * 0.13) {
            HStack(spacing: size * 0.16) {
                eye(t: t)
                eye(t: t)
            }
            mouth(t: t)
        }
        .offset(y: -size * 0.06)
    }

    private func eye(t: TimeInterval) -> some View {
        Capsule()
            .fill(Color(hex: 0x2B2320))
            .frame(
                width: size * 0.085,
                height: size * (blinking(t: t)
                    ? 0.02
                    : (isExcited || isWorking ? 0.17 : 0.12)))
            .offset(x: isIdle && !lively ? lookAround(t: t) : 0)
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
    var onHover: (Bool) -> Void
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
        view.onHover = onHover
        view.onDropText = onDropText
        view.onDropFile = onDropFile
        view.onDragChange = onDragChange
    }
}

final class DropCatcherView: NSView {
    var onHover: ((Bool) -> Void)?
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
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
