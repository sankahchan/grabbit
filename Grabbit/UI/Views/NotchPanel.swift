import AppKit
import Carbon
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
        /// Live-activity peek: a download was just added.
        case added(String)
    }

    private(set) var state: State = .idle(nil)
    /// A drag is hovering the pill — brighten the border and grow slightly.
    var isDragHover = false
    /// The mouse is over the island (boring.notch-style reveal).
    var isHover = false

    private var panel: NSPanel?
    private var timer: Timer?
    private var conflictTimer: Timer?
    /// True while the island is hidden because another notch app is running.
    private(set) var conflictHidden = false
    /// Recent download-speed samples (one per tick) for the sparkline.
    private(set) var speedHistory: [Double] = []
    /// Cursor position across the island (-1…1) for the mochi's parallax.
    private(set) var hoverX: CGFloat = 0
    /// Height of the physical notch (0 on non-notch Macs). The island hangs
    /// from the very top edge of the screen; content stays below this inset.
    private(set) var topInset: CGFloat = 0
    private var wasActive = false
    private var transientExpiry: Date?
    /// The last finish was a batch (>= 2 at once) — Mochi throws confetti.
    private var celebration = false
    /// When the menu opened — auto-collapse has a grace period so a
    /// spurious mouseExited during the window morph can't fold it instantly.
    private var menuOpenedAt: Date?
    /// Pending deferred menu-open (double-click mode).
    private var pendingMenuWork: DispatchWorkItem?

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

    enum SoundEvent {
        case offer
        case menu
        case added
        case done
        case failed
    }

    /// Tiny macOS system blips for Mochi's moments, per the chosen sound
    /// pack. Gated by settings and rate-limited so bursts stay polite.
    private func playSound(_ event: SoundEvent) {
        guard settings?.settings.notchSoundsEnabled != false else { return }
        let pack = settings?.settings.notchSoundPack ?? .cute
        let name: String?
        switch pack {
        case .off:
            name = nil
        case .cute:
            switch event {
            case .offer: name = "Pop"
            case .menu: name = "Tink"
            case .added: name = "Purr"
            case .done: name = "Glass"
            case .failed: name = "Basso"
            }
        case .subtle:
            switch event {
            case .offer: name = "Tink"
            case .menu: name = "Morse"
            case .added: name = "Pop"
            case .done: name = "Tink"
            case .failed: name = "Basso"
            }
        }
        guard let name else { return }
        guard settings?.settings.notchSoundPack != .off else { return }
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
        startConflictMonitor()
        registerGlobalHotkey()
        installRightClickMonitor()
        // Dev hooks: touch (or rm) these files to inspect island states.
        // `grabbit-force-menu` opens the menu; `grabbit-force-hover` fakes
        // the hover state so the layout can be screenshotted without a mouse.
        if FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Logs/grabbit-force-menu") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.handleTap()
                // Hold it open for inspection (grace never elapses).
                self?.menuOpenedAt = Date().addingTimeInterval(3600)
            }
        }
        if FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Logs/grabbit-force-hover") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.isHover = true
                self?.positionPanel(animated: false)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel(animated: false) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let panel else { return }
        if enabled && !conflictHidden {
            positionPanel(animated: false)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Notch-app conflict detection

    /// Pure name check (unit-testable): does the list of running app names
    /// include a known notch app? Any process whose name contains "notch"
    /// (boringNotch, NotchNook, notchy, NotchDrop, …) counts, plus a few
    /// well-known ones that don't (Alcove, MediaMate).
    nonisolated static func hasConflictingNotchApp(_ runningNames: [String]) -> Bool {
        let extra = ["alcove", "mediamate"]
        let lowered = runningNames.map { $0.lowercased() }
        for name in extra where lowered.contains(name) {
            return true
        }
        return lowered.contains { $0.contains("notch") }
    }

    private func startConflictMonitor() {
        updateConflictState()
        conflictTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateConflictState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        conflictTimer = timer
    }

    private func updateConflictState() {
        guard let panel else { return }
        let hide = Self.otherNotchAppRunning()
            || frontmostAppHidden()
            || fullscreenAppActive()
            || (settings?.settings.notchHiddenForSharing ?? false)
        guard hide != conflictHidden else { return }
        conflictHidden = hide
        debugLog("conflict: hide=\(hide)")
        if hide {
            panel.orderOut(nil)
        } else if settings?.settings.notchModeEnabled != false {
            positionPanel(animated: false)
            panel.orderFrontRegardless()
        }
    }

    /// The frontmost app is in the user's "hidden apps" list.
    private func frontmostAppHidden() -> Bool {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return settings?.settings.notchHiddenApps.contains(bundle) ?? false
    }

    /// A fullscreen window of the frontmost app covers its whole display.
    private func fullscreenAppActive() -> Bool {
        guard settings?.settings.notchHideInFullscreen == true else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        let totalTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let cgFrames = NSScreen.screens.map {
            CGRect(
                x: $0.frame.minX, y: totalTop - $0.frame.maxY,
                width: $0.frame.width, height: $0.frame.height)
        }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == front.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            for frame in cgFrames
            where abs(bounds.minX - frame.minX) < 2
                && abs(bounds.minY - frame.minY) < 2
                && abs(bounds.width - frame.width) < 2
                && abs(bounds.height - frame.height) < 2 {
                return true
            }
        }
        return false
    }

    private static func otherNotchAppRunning() -> Bool {
        let names: [String] = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular else { return nil }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return app.executableURL?.lastPathComponent
                ?? app.localizedName
                ?? ""
        }
        return hasConflictingNotchApp(names)
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
        panel.sharingType =
            settings?.settings.notchHideFromCapture == true ? .none : .readOnly
        // Above everything the system draws. On macOS 26+/27 the glass
        // menu bar rises above ordinary overlay levels the moment the
        // cursor approaches the top edge, leaving a "blank strip" over
        // the island. screenSaver is the level notch apps use to stay on
        // top of it.
        panel.level = .screenSaver
        // Keyboard nav (Esc / arrows / Enter) works without stealing the
        // user's active app: the panel becomes key only when needed.
        panel.becomesKeyOnlyIfNeeded = true
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
        guard let panel else { return }
        let scope = settings?.settings.notchDisplayScope ?? .main
        let screen: NSScreen?
        switch scope {
        case .main:
            screen = NSScreen.screens.first
        case .active:
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first {
                NSMouseInRect(mouse, $0.frame, false)
            } ?? NSScreen.screens.first
        }
        guard let screen else { return }
        let inset = screen.safeAreaInsets.top
        if topInset != inset { topInset = inset }
        let size = pillSize(for: state)
        // Pill mode: a capsule hanging below the menu bar. Notch mode:
        // flush with the screen top, blacking out the menu-bar strip center
        // like a hardware notch (Notchy's two shapes).
        let anchorY = shapeMode == .notch
            ? screen.frame.maxY
            : screen.visibleFrame.maxY
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: anchorY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    /// The island's current size. Only the *closed* pill scales/height-
    /// adjusts (Notchy's "Closed Pill Size" / "Pill Height Adjustment");
    /// hover and expanded sizes stay constant.
    func pillSize(for state: State) -> NSSize {
        switch state {
        case .idle(let offer):
            if offer != nil || isDragHover || isHover {
                return NSSize(width: 224, height: 40)
            }
            let scale = min(1.5, max(0.7, settings?.settings.notchClosedScale ?? 1))
            let widthMul = min(1.4, max(0.7, settings?.settings.notchClosedWidth ?? 1))
            let adjust = Double(min(20, max(-20, settings?.settings.notchHeightAdjust ?? 0)))
            return NSSize(
                width: 204 * scale * widthMul,
                height: max(24, 36 * scale + adjust))
        case .menu:
            return NSSize(width: 320, height: 176)
        case .active:
            return NSSize(width: 320, height: 56)
        case .done, .failed, .added:
            return NSSize(width: 240, height: 40)
        }
    }

    // MARK: - User settings accessors (live)

    var shapeMode: NotchShape { settings?.settings.notchShape ?? .pill }

    /// Morph spring per the user's motion settings.
    var morphAnimation: Animation {
        let style = settings?.settings.notchAnimationStyle ?? .snappy
        let base: Animation
        switch style {
        case .calm: base = .spring(response: 0.50, dampingFraction: 1.0)
        case .snappy: base = .spring(response: 0.34, dampingFraction: 0.8)
        case .bouncy: base = .spring(response: 0.38, dampingFraction: 0.6)
        }
        let speed = min(3.0, max(0.25, settings?.settings.notchAnimationSpeed ?? 1))
        return base.speed(speed)
    }

    /// Mochi animation level (full / subtle / off).
    var mochiLevel: NotchMochiLevel { settings?.settings.notchMochiLevel ?? .full }
    /// Top-edge highlight intensity (0–1).
    var edgeHighlight: Double {
        min(1, max(0, settings?.settings.notchEdgeHighlight ?? 1))
    }
    /// State-aura strength (0–1).
    var auraIntensity: Double {
        min(1, max(0, settings?.settings.notchAuraIntensity ?? 1))
    }
    /// Corner-roundness of the closed pill (0.3–1).
    var cornerScale: Double {
        min(1, max(0.3, settings?.settings.notchCornerScale ?? 1))
    }
    var showClock: Bool { settings?.settings.notchShowClock ?? false }
    /// Bumped every tick so the view re-renders the clock (minute text).
    private(set) var clockTick = 0

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var clockText: String { Self.clockFormatter.string(from: Date()) }

    /// Whether the closed pill shows anything at rest (Notchy's
    /// Always / Only-when-active / Only-on-hover visibility modes).
    func showsRestContent(offer: Offer?) -> Bool {
        if isHover || isDragHover || offer != nil { return true }
        switch settings?.settings.notchVisibility ?? .always {
        case .always: return true
        case .activeOnly: return hasTasks
        case .hoverOnly: return false
        }
    }

    /// Any download/torrent task exists.
    var hasTasks: Bool {
        !(downloadEngine?.items ?? []).isEmpty
            || !(torrentEngine?.torrents ?? []).isEmpty
    }

    var glassEnabled: Bool { settings?.settings.notchGlassEnabled ?? true }
    var auraEnabled: Bool { settings?.settings.notchAuraEnabled ?? true }
    var translucency: Double { min(1.0, max(0.5, settings?.settings.notchTranslucency ?? 0.97)) }

    /// The user's custom closed-island fill, when enabled.
    var customFill: Color? {
        guard settings?.settings.notchCustomFill == true,
              let hex = settings?.settings.notchFillColor
        else { return nil }
        return Color(hexString: hex)
    }

    /// Re-applies user settings that live on the panel window itself.
    func applySettings() {
        guard let panel else { return }
        panel.sharingType =
            settings?.settings.notchHideFromCapture == true ? .none : .readOnly
        registerGlobalHotkey()
        updateConflictState()
        setEnabled(settings?.settings.notchModeEnabled ?? true)
    }

    /// Right-clicking the island jumps straight to its settings page.
    func openSettings() {
        navigation?.selection = .settings
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        collapse()
    }

    private var rightClickMonitor: Any?

    /// A local monitor so a right-click anywhere on the island (including
    /// over the SwiftUI button) opens Settings.
    private func installRightClickMonitor() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .rightMouseDown
        ) { [weak self] event in
            guard let self, let panel = self.panel,
                  event.window == panel else { return event }
            Task { @MainActor in self.openSettings() }
            return nil
        }
    }

    // MARK: - Global hotkey (⌃⌘N)

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    /// Registers or clears the global hotkey per settings. Carbon hotkeys
    /// need no accessibility permission.
    func registerGlobalHotkey() {
        let wanted = settings?.settings.notchHotkeyEnabled == true
        if wanted, hotKeyRef != nil { return }
        if !wanted, hotKeyRef == nil, hotKeyHandlerRef == nil { return }
        unregisterGlobalHotkey()
        guard wanted else { return }
        var hotKeyID = EventHotKeyID(signature: OSType(0x47524248), id: 1)
        let modifiers = UInt32(controlKey | cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            debugLog("hotkey: register failed \(status)")
            return
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let controller = Unmanaged<NotchController>
                    .fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in controller.hotkeyToggle() }
                return noErr
            },
            1, &eventType, selfPtr, &hotKeyHandlerRef)
        debugLog("hotkey: registered ^cmd-N")
    }

    private func unregisterGlobalHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    /// ⌃⌘N: open the island's menu, or fold it when already open.
    func hotkeyToggle() {
        debugLog("hotkey: toggle")
        if case .menu = state {
            collapse()
        } else {
            openMenu()
        }
    }

    // MARK: - Preview

    /// Cycles idle → hover → menu so settings changes can be previewed.
    func runPreview() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            setEnabled(settings?.settings.notchModeEnabled ?? true)
            collapse()
            applyHover(false)
            try? await Task.sleep(nanoseconds: 900_000_000)
            applyHover(true)
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            applyHover(false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            openMenu()
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            collapse()
        }
    }

    // MARK: - Keyboard (menu navigation)

    /// The row the arrow keys point at while the menu is open.
    private(set) var menuSelection = 0
    /// The island's window holds keyboard focus (without activating the app).
    private(set) var keyFocus = false

    enum MenuItem: Int, CaseIterable {
        case link
        case toggle
        case openApp
    }

    /// The rows actually shown, in order.
    var menuItems: [MenuItem] {
        clipboardOffer == nil ? [.toggle, .openApp] : [.link, .toggle, .openApp]
    }

    func handleKey(_ key: String) {
        guard case .menu = state else { return }
        switch key {
        case "esc":
            collapse()
        case "up", "down":
            let items = menuItems
            guard !items.isEmpty else { return }
            if key == "up" {
                menuSelection = (menuSelection - 1 + items.count) % items.count
            } else {
                menuSelection = (menuSelection + 1) % items.count
            }
        case "enter":
            let items = menuItems
            guard menuSelection < items.count else { return }
            switch items[menuSelection] {
            case .link:
                addFromClipboard()
            case .toggle:
                if isBusy { pauseAll() } else { resumeAll() }
            case .openApp:
                openApp()
            }
        default:
            break
        }
    }

    // MARK: - Mochi mood

    /// The mochi's mood for a given pill state, from live engine signals.
    func mochiMood(for state: State) -> MochiMood {
        switch state {
        case .idle(let offer):
            return NotchMoodPicker.idleMood(
                offer: offer != nil,
                vpnBlocked: torrentEngine?.vpnHolding ?? false,
                seeding: isSeeding,
                probing: mediaEngine?.state == .probing,
                diskLow: diskLow(),
                allPausedWithTasks: allPausedWithTasks())
        case .menu(let offer):
            return offer == nil ? .idle : .excited
        case .active(let progress, let speed):
            return NotchMoodPicker.activeMood(
                vpnBlocked: torrentEngine?.vpnHolding ?? false,
                speed: speed,
                progress: progress)
        case .done:
            return celebration ? .confetti : .done
        case .failed:
            return .sad
        case .added:
            return .excited
        }
    }

    private var isSeeding: Bool {
        torrentEngine?.torrents.contains { $0.state == .seeding } ?? false
    }

    /// Tasks exist but nothing is moving — Mochi dozes off.
    private func allPausedWithTasks() -> Bool {
        let downloads = downloadEngine?.items ?? []
        let torrents = torrentEngine?.torrents ?? []
        guard !downloads.isEmpty || !torrents.isEmpty else { return false }
        let anyActive = downloads.contains { $0.state == .downloading }
            || torrents.contains {
                $0.state == .downloading || $0.state == .seeding
            }
        guard !anyActive else { return false }
        return !downloads.contains { $0.state == .failed }
            && !torrents.contains { $0.state == .failed }
    }

    private var lastDiskCheck: Date?
    private var lastDiskLow = false

    /// Less than 500 MB of important space left — Mochi gets worried.
    private func diskLow() -> Bool {
        let now = Date()
        if let lastDiskCheck, now.timeIntervalSince(lastDiskCheck) < 5 {
            return lastDiskLow
        }
        lastDiskCheck = now
        let url = settings?.folderURL(for: .other)
            ?? FileManager.default.homeDirectoryForCurrentUser
        let free = (try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage) ?? 0
        lastDiskLow = free < 500_000_000
        return lastDiskLow
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

        // While the menu is open, don't fight the user's interaction —
        // but fold it back when the mouse has wandered off. Catches
        // tracking-area exits missed while the window was morphing.
        if case .menu = state {
            let timeout = settings?.settings.notchIdleTimeout ?? 0
            if timeout > 0, let opened = menuOpenedAt,
               Date().timeIntervalSince(opened) > timeout {
                debugLog("collapse: idle timeout")
                collapse()
                return
            }
            if menuGraceElapsed,
               let panel, !panel.frame.contains(NSEvent.mouseLocation) {
                debugLog("collapse: outside frame")
                collapse()
            }
            return
        }
        // A just-added peek holds its moment before the normal state logic
        // takes over again.
        if case .added = state {
            if let expiry = transientExpiry, Date() > expiry {
                state = .idle(clipboardOffer)
                transientExpiry = nil
            }
            positionPanel(animated: true)
            return
        }

        // Self-heal hover state: tracking areas can miss an enter after a
        // resize — trust the actual cursor position once a tick.
        if !isHover, settings?.settings.notchExpandOnHover ?? true,
           let panel, panel.frame.contains(NSEvent.mouseLocation) {
            wantsHover = true
            isHover = true
            positionPanel(animated: true)
        }

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

        let showProgress = settings?.settings.notchShowProgress ?? true
        if active, showProgress {
            state = .active(progress: min(1, max(0, progress)), speedBytes: speed)
            speedHistory.append(speed)
            if speedHistory.count > 24 {
                speedHistory.removeFirst(speedHistory.count - 24)
            }
            wasActive = true
            transientExpiry = nil
        } else if wasActive {
            let failedName = downloadEngine.items.first { $0.state == .failed }?.filename
                ?? torrentEngine.torrents.first { $0.state == .failed }?.name
            if let failedName, settings?.settings.notchShowFailed ?? true {
                state = .failed(failedName)
                playSound(.failed)
            } else if failedName == nil,
                      settings?.settings.notchShowFinished ?? true {
                state = .done("")
                playSound(.done)
                let finished = downloadEngine.items.filter {
                    $0.state == .completed
                }.count + torrentEngine.torrents.filter {
                    $0.state == .seeding || $0.state == .completed
                }.count
                celebration = finished >= 2
            }
            transientExpiry = Date().addingTimeInterval(transientSeconds)
            wasActive = false
            speedHistory.removeAll()
        } else if let expiry = transientExpiry, Date() > expiry {
            state = .idle(clipboardOffer)
            transientExpiry = nil
            celebration = false
        } else {
            // Keep the idle badge in sync with a freshly copied link.
            state = .idle(clipboardOffer)
        }

        clockTick &+= 1
        if settings?.settings.notchDisplayScope == .active {
            positionPanel(animated: false)
        } else {
            positionPanel(animated: true)
        }
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
            playSound(.offer)
        }
        clipboardOffer = offer
        // The menu may be open with a row selected that no longer exists.
        if case .menu = state {
            menuSelection = min(menuSelection, max(0, menuItems.count - 1))
        }
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
        // Double-click mode: the menu opens on a short delay so a second
        // tap can be recognised and open the app instead.
        if settings?.settings.notchDoubleClickOpensApp == true {
            if let pending = pendingMenuWork {
                pending.cancel()
                pendingMenuWork = nil
                debugLog("handleTap: double-click -> open app")
                openApp()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.openMenu() }
            }
            pendingMenuWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.28, execute: work)
        } else {
            openMenu()
        }
    }

    private func openMenu() {
        debugLog("handleTap: opening menu (offer=\(String(describing: clipboardOffer)))")
        debugTouchLog("menuOpen")
        playSound(.menu)
        state = .menu(clipboardOffer)
        menuOpenedAt = Date()
        menuSelection = 0
        keyFocus = true
        positionPanel(animated: true)
    }

    func collapse() {
        pendingMenuWork?.cancel()
        pendingMenuWork = nil
        state = .idle(clipboardOffer)
        menuOpenedAt = nil
        keyFocus = false
        positionPanel(animated: true)
    }

    /// True once the menu has been open long enough that folding it on
    /// mouse-leave is safe (a resize can emit a phantom mouseExited).
    private var menuGraceElapsed: Bool {
        guard let menuOpenedAt else { return true }
        let delay = max(0, settings?.settings.notchCollapseDelay ?? 0.9)
        return Date().timeIntervalSince(menuOpenedAt) > delay
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

    /// Mouse-move parallax from the drop zone (event-driven, so it is
    /// smooth — not tied to the 0.5s state tick).
    func setGaze(_ x: CGFloat) {
        if abs(x - hoverX) > 0.02 { hoverX = x }
    }

    /// Dev hook: `touch ~/Library/Logs/grabbit-touch-log` logs the panel
    /// geometry on every real hover/click so issues can be diagnosed.
    private func debugTouchLog(_ context: String) {
        guard FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Logs/grabbit-touch-log") else { return }
        guard let screen = NSScreen.screens.first else { return }
        let f = panel?.frame ?? .zero
        debugLog("touchLog[\(context)]: panel=\(f) screen=\(screen.frame) vis=\(screen.visibleFrame) inset=\(screen.safeAreaInsets.top) mouse=\(NSEvent.mouseLocation) level=\(panel?.level.rawValue ?? -1)")
    }

    private var wantsHover = false
    private var hoverWorkItem: DispatchWorkItem?

    func setHover(_ hovering: Bool) {
        guard wantsHover != hovering else { return }
        wantsHover = hovering
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        guard hovering else {
            applyHover(false)
            return
        }
        guard settings?.settings.notchExpandOnHover ?? true else { return }
        let delay = max(0, settings?.settings.notchHoverDelay ?? 0)
        if delay == 0 {
            applyHover(true)
        } else {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.applyHover(true) }
            }
            hoverWorkItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay, execute: item)
        }
    }

    private func applyHover(_ hovering: Bool) {
        guard isHover != hovering else { return }
        isHover = hovering
        if !hovering {
            pendingMenuWork?.cancel()
            pendingMenuWork = nil
        }
        debugTouchLog(hovering ? "hoverIn" : "hoverOut")
        // Leaving the island folds an open menu back into the tab — it
        // never lingers open (boring.notch behavior). Only fold when the
        // cursor is *really* outside and the menu has settled, so a
        // phantom mouseExited during the window morph can't kill it.
        if !hovering, case .menu = state, menuGraceElapsed,
           let panel, !panel.frame.contains(NSEvent.mouseLocation) {
            debugLog("collapse: real mouse exit")
            collapse()
            return
        }
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
        if case .invalid = kind {} else { playSound(.added) }
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
        // Live-activity peek: the island pops open with the new item's
        // name for a couple of seconds, then folds back.
        guard settings?.settings.notchShowAdded ?? true else { return }
        state = .added(message)
        transientExpiry = Date().addingTimeInterval(transientSeconds)
        positionPanel(animated: true)
    }

    /// Seconds transient popups stay visible.
    private var transientSeconds: Double {
        min(10, max(1, settings?.settings.notchTransientSeconds ?? 2.5))
    }

    private func showTransientFailure(_ message: String) {
        state = .failed(message)
        transientExpiry = Date().addingTimeInterval(transientSeconds)
        positionPanel(animated: true)
    }
}

// MARK: - Pill view

struct NotchPillView: View {
    @Bindable var controller: NotchController

    /// Safe in a non-activating panel (unlike TimelineView, which broke
    /// button rendering here): rim pulse + shine sweep via repeatForever.
    @State private var rimPulse = false
    @State private var sweepRun = false

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
            color: .black.opacity(isExpanded(state) ? 0.38 : 0.12),
            radius: 12, y: 6)
        .background(
            NotchDropZone(
                onGaze: { controller.setGaze($0) },
                onHover: { controller.setHover($0) },
                onDropText: { controller.handleDrop(text: $0) },
                onDropFile: { controller.handleDrop(fileURL: $0) },
                onDragChange: { controller.setDragHover($0) },
                onKey: { controller.handleKey($0) },
                wantKeyFocus: controller.keyFocus)
        )
        .animation(controller.morphAnimation, value: controller.state)
        .animation(.easeInOut(duration: 0.12), value: controller.isDragHover)
        .animation(controller.morphAnimation, value: controller.isHover)
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

    /// A Notchy-style capsule hanging from the menu bar's bottom edge:
    /// fully rounded, expands on hover, grows into a card when in use.
    private func capsule(for state: NotchController.State) -> some View {
        let hideRest: Bool = {
            if case .idle(let offer) = state {
                return !controller.showsRestContent(offer: offer)
            }
            return false
        }()
        return ZStack {
            if hideRest {
                // Visibility modes can park the closed pill: the window
                // stays for hover/drop detection but shows nothing.
                Color.clear
            } else {
                glassBase(for: state)
                if controller.edgeHighlight > 0 {
                    edgeHighlightLayer
                        .opacity(controller.edgeHighlight)
                }
                if controller.auraEnabled {
                    bottomAura(for: state)
                        .opacity(
                            (rimPulse ? 1.0 : 0.65)
                                * controller.auraIntensity)
                }
                shineSweep(for: state, phase: sweepRun ? 1 : 0)
                content(for: state)
            }
        }
        .frame(width: size(for: state).width, height: size(for: state).height)
        .clipShape(tabShape(for: state))
        .onAppear {
            withAnimation(
                .easeInOut(duration: 2.6).repeatForever(autoreverses: true)
            ) {
                rimPulse = true
            }
            withAnimation(
                .linear(duration: 7).repeatForever(autoreverses: false)
            ) {
                sweepRun = true
            }
        }
    }

    /// A soft light along the top edge (Notchy's "Edge Highlight").
    private var edgeHighlightLayer: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 3)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    /// A diagonal glint that crosses the island every few seconds.
    private func shineSweep(
        for state: NotchController.State, phase: Double
    ) -> some View {
        let w = size(for: state).width
        return LinearGradient(
            colors: [.clear, .white.opacity(0.07), .clear],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: w * 0.6, height: size(for: state).height * 2)
            .rotationEffect(.degrees(16))
            .offset(x: -w + CGFloat(phase) * (w * 2.0))
            .allowsHitTesting(false)
    }

    /// The island's fill: dark glass, a flat fill, or the user's color.
    private func glassBase(for state: NotchController.State) -> some View {
        let opacity = controller.translucency
        let fill: AnyShapeStyle
        if let custom = controller.customFill {
            fill = AnyShapeStyle(custom.opacity(opacity))
        } else if controller.glassEnabled {
            fill = AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(hex: 0x1B2029).opacity(opacity),
                        Color(hex: 0x0A0C11).opacity(min(1, opacity + 0.02)),
                    ],
                    startPoint: .top, endPoint: .bottom))
        } else {
            fill = AnyShapeStyle(Color(hex: 0x0B0D12).opacity(opacity))
        }
        return tabShape(for: state)
            .fill(fill)
            .allowsHitTesting(false)
    }

    /// A soft breath of color rising from the bottom edge — the island's
    /// mood lighting. Hard gradient rings and stroked shapes don't render
    /// reliably in this panel; a soft internal LinearGradient does.
    private func bottomAura(for state: NotchController.State) -> some View {
        let color: Color = {
            if controller.isDragHover { return .white }
            switch state {
            case .idle, .menu: return Color(hex: 0xB06CF9)
            case .active: return Neo.blue
            case .done: return Neo.green
            case .failed: return Color(hex: 0xFF5A5A)
            case .added: return Neo.blue
            }
        }()
        let strength: Double = controller.isDragHover ? 0.55 : 0.38
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0.5),
                .init(color: color.opacity(strength), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    /// Pill mode: a fully-rounded capsule / card. Notch mode: square top
    /// flush with the screen edge, rounded bottom — Notchy's two shapes.
    private func tabShape(for state: NotchController.State) -> AnyShape {
        let closed: Bool
        if case .idle = state { closed = true } else { closed = false }
        let size = self.size(for: state)
        let radius = closed
            ? (size.height / 2) * controller.cornerScale
            : 26
        if controller.shapeMode == .notch {
            return AnyShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: radius,
                    bottomTrailingRadius: radius,
                    topTrailingRadius: 0,
                    style: .continuous))
        }
        return AnyShape(
            RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func isExpanded(_ state: NotchController.State) -> Bool {
        if case .idle = state { return false }
        return true
    }

    @ViewBuilder
    private func content(for state: NotchController.State) -> some View {
        switch state {
        case .idle(let offer):
            if controller.showsRestContent(offer: offer) {
                idleRow(offer, mood: controller.mochiMood(for: state))
            }

        case .menu(let offer):
            menuContent(offer)

        case .active(let progress, let speed):
            activeRow(progress: progress, speed: speed)

        case .done:
            HStack(spacing: 7) {
                mochi(mood: controller.mochiMood(for: state), size: 24)
                Text(NSLocalizedString("notch.done", comment: ""))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
            }

        case .failed(let name):
            HStack(spacing: 7) {
                mochi(mood: .sad, size: 24)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

        case .added(let name):
            HStack(spacing: 8) {
                mochi(mood: controller.mochiMood(for: state), size: 24, lively: true)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Neo.blue)
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func idleRow(
        _ offer: NotchController.Offer?, mood: MochiMood
    ) -> some View {
        let mochiOn = controller.mochiLevel != .off
        let clockOn = controller.showClock && offer == nil
            && !controller.isHover
        // Reading clockTick when the clock shows makes the view re-render
        // every tick, so the time stays fresh.
        _ = clockOn ? controller.clockTick : 0
        return HStack(spacing: 7) {
            if mochiOn {
                mochi(
                    mood: mood,
                    size: offer == nil ? (controller.isHover ? 26 : 22) : 24,
                    lively: controller.isHover)
            }
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
            } else if clockOn {
                if mochiOn { Spacer(minLength: 10) }
                Text(controller.clockText)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if mochiOn { Spacer(minLength: 10) }
            } else if !mochiOn {
                Text("Grabbit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, clockOn && mochiOn ? 16 : 0)
        .frame(maxWidth: clockOn && mochiOn ? .infinity : nil)
    }

    /// Mochi with the user's animation level applied (off = hidden).
    @ViewBuilder
    private func mochi(
        mood: MochiMood, size: CGFloat, lively: Bool = false
    ) -> some View {
        if controller.mochiLevel != .off {
            MochiView(
                mood: mood,
                size: size,
                lively: lively,
                gazeX: controller.hoverX,
                animated: controller.mochiLevel == .full)
        }
    }

    @ViewBuilder
    private func menuContent(_ offer: NotchController.Offer?) -> some View {
        VStack(spacing: 6) {
            mochi(
                mood: controller.mochiMood(for: .menu(offer)),
                size: 30, lively: true)
            let items = controller.menuItems
            let selected = min(controller.menuSelection, max(0, items.count - 1))
            if let offer {
                NotchLinkCard(
                    offer: offer,
                    selected: items[selected] == .link
                ) {
                    controller.addFromClipboard()
                }
            } else {
                emptyLinkHint
            }
            VStack(spacing: 2) {
                NotchMenuRow(
                    icon: controller.isBusy ? "pause.fill" : "play.fill",
                    color: controller.isBusy ? Neo.yellow : Neo.green,
                    label: NSLocalizedString(
                        controller.isBusy
                            ? "notch.menu.pauseAll"
                            : "notch.menu.resumeAll", comment: ""),
                    selected: items[selected] == .toggle) {
                    if controller.isBusy {
                        controller.pauseAll()
                    } else {
                        controller.resumeAll()
                    }
                }
                NotchMenuRow(
                    icon: "macwindow", color: .white.opacity(0.85),
                    label: NSLocalizedString("notch.menu.open", comment: ""),
                    selected: items[selected] == .openApp) {
                    controller.openApp()
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .padding(.horizontal, 10)
    }

    private var emptyLinkHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Neo.blue)
                .frame(width: 22, height: 22)
                .background(
                    Neo.blue.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(NSLocalizedString("notch.menu.noLink", comment: ""))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func activeRow(progress: Double, speed: Double) -> some View {
        let mood = controller.mochiMood(
            for: .active(progress: progress, speedBytes: speed))
        ZStack(alignment: .bottom) {
            HStack(spacing: 10) {
                mochi(mood: mood, size: 30, lively: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("↓ \(formatBytes(Int64(speed)))/s")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Neo.blue)
                }
                Spacer(minLength: 8)
                SpeedSparkline(values: controller.speedHistory)
                EqualizerBars(
                    level: min(1, speed / 8_000_000),
                    animated: controller.mochiLevel == .full)
                if controller.isHover {
                    Image(systemName: "chevron.up.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            LiquidProgress(progress: progress)
        }
    }

    private func size(for state: NotchController.State) -> CGSize {
        let ns = controller.pillSize(for: state)
        return CGSize(width: ns.width, height: ns.height)
    }
}

// MARK: - Island components

/// A menu action row: colored icon chip + label, with a hover glow.
private struct NotchMenuRow: View {
    var icon: String
    var color: Color
    var label: String
    var selected: Bool = false
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(
                        color.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected
                        ? color.opacity(0.18)
                        : .white.opacity(hovered ? 0.08 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(color.opacity(selected ? 0.6 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The detected-link card at the top of the menu, with an ADD pill.
private struct NotchLinkCard: View {
    var offer: NotchController.Offer
    var selected: Bool = false
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: offer.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Neo.blue)
                    .frame(width: 24, height: 24)
                    .background(
                        Neo.blue.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(offer.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(NSLocalizedString("notch.menu.add", comment: ""))
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(Neo.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Neo.blue.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Neo.blue.opacity(selected ? 0.2 : (hovered ? 0.13 : 0.07))))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Neo.blue.opacity(selected ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Full-width liquid progress line along the bottom of the active card.
private struct LiquidProgress: View {
    var progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Neo.blue, Color(hex: 0x5AC8FA)],
                            startPoint: .leading, endPoint: .trailing))
                    .frame(
                        width: max(3, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3.5)
        .allowsHitTesting(false)
    }
}

/// Live download-speed sparkline (last ~12 seconds).
private struct SpeedSparkline: View {
    var values: [Double]
    var color: Color = Neo.blue

    var body: some View {
        let samples = Array(values.suffix(24))
        GeometryReader { geo in
            sparkPath(samples: samples, geo: geo)
        }
        .frame(width: 54, height: 16)
        .allowsHitTesting(false)
    }

    private func sparkPath(samples: [Double], geo: GeometryProxy) -> some View {
        let maxV = max(samples.max() ?? 1, 1)
        let stepX = geo.size.width / CGFloat(max(samples.count - 1, 1))
        var path = Path()
        var first = true
        for (i, v) in samples.enumerated() {
            let x = CGFloat(i) * stepX
            let y = geo.size.height * (1 - CGFloat(v / maxV) * 0.88)
            if first {
                path.move(to: CGPoint(x: x, y: y))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path.stroke(
            color,
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
}

/// Four dancing bars — the island's download equalizer.
private struct EqualizerBars: View {
    var level: Double
    var color: Color = Neo.blue
    /// Full mochi level animates; lower levels show a calm static frame.
    var animated: Bool = true

    private static let pattern: [Double] = [0.5, 0.9, 0.65, 0.8]

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 2) {
                    bar(i: 0, t: t)
                    bar(i: 1, t: t)
                    bar(i: 2, t: t)
                    bar(i: 3, t: t)
                }
                .frame(height: 14, alignment: .bottom)
                .allowsHitTesting(false)
            }
        } else {
            HStack(alignment: .bottom, spacing: 2) {
                staticBar(i: 0)
                staticBar(i: 1)
                staticBar(i: 2)
                staticBar(i: 3)
            }
            .frame(height: 14, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    private func staticBar(i: Int) -> some View {
        let energy = max(0.15, min(1, level))
        let h = 3 + (11 * energy) * Self.pattern[i]
        return Capsule()
            .fill(color.opacity(0.9))
            .frame(width: 2.5, height: h)
    }

    private func bar(i: Int, t: TimeInterval) -> some View {
        let energy = max(0.15, min(1, level))
        let rate = 3.5 + energy * 7
        let h = 3 + (11 * energy) * abs(sin(t * rate + Double(i) * 1.1))
        return Capsule()
            .fill(color.opacity(0.9))
            .frame(width: 2.5, height: h)
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
    case sleeping
    case seeding
    case thinking
    case alert
    case turbo
    case confetti
    case worried
}

/// Pure mood resolution (unit-testable): maps the app's live conditions
/// onto a Mochi mood. Priority: offer > VPN alert > seeding > probing >
/// disk worry > all-paused sleep > plain idle; active: VPN > turbo > work.
enum NotchMoodPicker {
    /// Speed (bytes/sec) above which Mochi catches fire.
    static let turboThreshold: Double = 5_000_000

    static func idleMood(
        offer: Bool,
        vpnBlocked: Bool,
        seeding: Bool,
        probing: Bool,
        diskLow: Bool,
        allPausedWithTasks: Bool
    ) -> MochiMood {
        if offer { return .excited }
        if vpnBlocked { return .alert }
        if seeding { return .seeding }
        if probing { return .thinking }
        if diskLow { return .worried }
        if allPausedWithTasks { return .sleeping }
        return .idle
    }

    static func activeMood(
        vpnBlocked: Bool, speed: Double, progress: Double
    ) -> MochiMood {
        if vpnBlocked { return .alert }
        if speed >= turboThreshold { return .turbo }
        return .working(progress)
    }
}

/// A soft cream mochi drawn with plain SwiftUI shapes — no image assets.
/// It is never still: it breathes, looks around, blinks, hops, and every
/// mood dresses it up in its own colors — a leaf sprout on its head, a
/// colored halo, sparkles, flames, shields, thought bubbles, confetti.
struct MochiView: View {
    var mood: MochiMood = .idle
    var size: CGFloat = 18
    /// Extra liveliness for hover moments (pops up + sparkles).
    var lively: Bool = false
    /// Cursor position across the island (-1…1) — the mochi follows it.
    var gazeX: CGFloat = 0
    /// Full = animated timeline; false = a calm static pose (battery).
    var animated: Bool = true

    @State private var pop = false

    private var isWorking: Bool {
        if case .working = mood { return true }
        return false
    }

    private var isExcited: Bool { mood == .excited }
    private var isIdle: Bool { mood == .idle }

    /// Each mood dresses the mochi in its own color.
    private var accent: Color {
        switch mood {
        case .idle: Color(hex: 0xFF9EB5)
        case .excited: Neo.yellow
        case .working: Neo.blue
        case .done: Neo.green
        case .sad: Neo.blue
        case .sleeping: Color(hex: 0xB39DDB)
        case .seeding: Neo.green
        case .thinking: Neo.purple
        case .alert: Color(hex: 0xFF5A5A)
        case .turbo: Color(hex: 0xFF8A3D)
        case .confetti: Neo.yellow
        case .worried: Color(hex: 0xFFC94D)
        }
    }

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 0.08)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                posedContent(t: t)
            }
            .onChange(of: lively) { _, on in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                    pop = on
                }
            }
        } else {
            posedContent(t: 0.6)
        }
    }

    /// One rendered frame of the mochi at time `t`.
    private func posedContent(t: TimeInterval) -> some View {
        ZStack {
            halo
            bodyShape
            face(t: t)
            accessories(t: t)
        }
        .frame(width: size, height: size)
        .scaleEffect(
            x: pop ? 1.10 : 1,
            y: (pop ? 1.10 : 1) * breathing(t: t),
            anchor: .bottom)
        .offset(x: shake(t: t) + gazeX * size * 0.035, y: bounce(t: t))
        .rotationEffect(.degrees(tilt(t: t)))
    }

    // MARK: Motion

    /// A soft colored glow behind the body.
    private var halo: some View {
        Ellipse()
            .fill(accent.opacity(mood == .idle ? 0.10 : 0.22))
            .blur(radius: size * 0.10)
            .frame(width: size * 1.06, height: size * 0.96)
            .allowsHitTesting(false)
    }

    /// Slow breathing, plus a squash-and-stretch hop every ~8 seconds.
    private func breathing(t: TimeInterval) -> CGFloat {
        guard isIdle || mood == .done || mood == .sleeping else { return 1 }
        let period: Double = mood == .sleeping ? 4.2 : 2.8
        let breath = 1 + 0.045 * sin(t * 2 * .pi / period)
        if isIdle {
            let c = t.truncatingRemainder(dividingBy: 8)
            if c > 7.30, c < 7.90 {
                let pp = (c - 7.30) / 0.60
                return breath * (1 - 0.16 * sin(pp * .pi))
            }
        }
        return breath
    }

    /// Little hops: calm states every ~8s, excited/turbo/confetti bounce,
    /// working bobs.
    private func bounce(t: TimeInterval) -> CGFloat {
        if isExcited { return -2.2 * abs(sin(t * 5)) }
        if isWorking { return -1.6 * abs(sin(t * 7)) }
        if mood == .turbo { return -2.6 * abs(sin(t * 9)) }
        if mood == .confetti { return -4.0 * abs(sin(t * 5)) }
        if mood == .sad { return 1.2 }
        guard isIdle, !lively else { return 0 }
        let c = t.truncatingRemainder(dividingBy: 8)
        guard c > 7.35, c < 7.85 else { return 0 }
        let pp = (c - 7.35) / 0.50
        return -5.5 * sin(pp * .pi)
    }

    /// Alert and worry tremble slightly from side to side.
    private func shake(t: TimeInterval) -> CGFloat {
        if mood == .alert { return 0.8 * sin(t * 18) }
        if mood == .worried { return 0.5 * sin(t * 12) }
        return 0
    }

    private func tilt(t: TimeInterval) -> Double {
        if isWorking { return 3.5 * sin(t * 8) }
        if mood == .seeding { return 3 * sin(t * 2.2) }
        if mood == .thinking { return 2 * sin(t * 3) }
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

    private var bodyShape: some View {
        let bodyGradient = LinearGradient(
            colors: [Color(hex: 0xFFFBF2), Color(hex: 0xFFE3C9)],
            startPoint: .top, endPoint: .bottom)
        let outline = Color(hex: 0x6B4A3A).opacity(0.35)
        let highlight = Ellipse()
            .fill(Color.white.opacity(0.55))
            .frame(width: size * 0.34, height: size * 0.20)
        let cheekRow = HStack(spacing: size * 0.52) {
            cheek
            cheek
        }
        return Ellipse()
            .fill(bodyGradient)
            .overlay(
                Ellipse()
                    .stroke(outline, lineWidth: max(0.8, size * 0.035))
                    .allowsHitTesting(false))
            .overlay(
                highlight
                    .offset(x: -size * 0.18, y: -size * 0.16)
                    .allowsHitTesting(false))
            .frame(width: size * 0.92, height: size * 0.82)
            .overlay(
                cheekRow
                    .frame(width: size * 0.14, height: size * 0.07)
                    .offset(y: size * 0.07)
                    .allowsHitTesting(false))
    }

    private var cheek: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xFFB3A7), Color(hex: 0xFF9EB5)],
                    startPoint: .top, endPoint: .bottom))
            .frame(width: size * 0.13, height: size * 0.07)
    }

    /// The little green leaf sprout on top of its head.
    private func leaf(t: TimeInterval) -> some View {
        ZStack {
            Capsule()
                .fill(Color(hex: 0x4C9A52))
                .frame(width: size * 0.04, height: size * 0.16)
                .offset(y: -size * 0.46)
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x7CCB7F), Color(hex: 0x4C9A52)],
                        startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.16, height: size * 0.30)
                .rotationEffect(.degrees(leafAngle(t: t)))
                .offset(x: size * 0.10, y: -size * 0.52)
        }
        .allowsHitTesting(false)
    }

    private func leafAngle(t: TimeInterval) -> Double {
        switch mood {
        case .sad: return 105
        case .alert: return 40
        case .excited, .turbo, .confetti: return 15 + 6 * sin(t * 8)
        default: return 60 + 8 * sin(t * 2.2)
        }
    }

    // MARK: Face

    private func face(t: TimeInterval) -> some View {
        VStack(spacing: size * 0.13) {
            HStack(spacing: size * 0.17) {
                eye(t: t)
                eye(t: t)
            }
            mouth(t: t)
        }
        .offset(y: -size * 0.06 + eyeLift)
    }

    private var eyeLift: CGFloat {
        switch mood {
        case .thinking: -size * 0.05
        case .sleeping: size * 0.02
        case .worried: -size * 0.02
        default: 0
        }
    }

    @ViewBuilder
    private func eye(t: TimeInterval) -> some View {
        if mood == .sleeping {
            Capsule()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * 0.10, height: size * 0.022)
        } else {
            let big = isExcited || isWorking || mood == .turbo
                || mood == .confetti || mood == .alert
            ZStack {
                Ellipse()
                    .fill(Color(hex: 0x2B2320))
                    .frame(
                        width: size * 0.10,
                        height: size * (blinking(t: t)
                            ? 0.025
                            : (big ? 0.19 : 0.14)))
                if !blinking(t: t) {
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: size * 0.035, height: size * 0.035)
                        .offset(x: size * 0.018, y: -size * 0.028)
                }
            }
            .offset(
                x: (isIdle && !lively ? lookAround(t: t) : 0)
                    + gazeX * size * 0.06)
        }
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
            arcMouth(frowning: true, width: size * 0.17)
        case .done, .seeding:
            arcMouth(frowning: false, width: size * 0.13)
        case .confetti, .turbo:
            arcMouth(frowning: false, width: size * 0.22)
        case .worried:
            arcMouth(frowning: true, width: size * 0.11)
                .scaleEffect(0.75)
        case .sleeping:
            Circle()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * 0.05, height: size * 0.05)
        case .alert, .thinking:
            Circle()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * 0.07, height: size * 0.07)
        case .idle, .excited:
            Capsule()
                .fill(Color(hex: 0x2B2320))
                .frame(width: size * 0.09, height: size * 0.035)
        }
    }

    private func arcMouth(frowning: Bool, width: CGFloat) -> some View {
        Path { path in
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
        .frame(width: width, height: size * 0.15)
    }

    // MARK: Accessories

    @ViewBuilder
    private func accessories(t: TimeInterval) -> some View {
        leaf(t: t)
        switch mood {
        case .excited, .done:
            sparklePair(t: t)
        case .confetti:
            confettiBurst(t: t)
        case .sleeping:
            zzz(t: t)
        case .seeding:
            Image(systemName: "leaf.fill")
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(Neo.green)
                .offset(x: size * 0.30, y: -size * 0.30)
                .allowsHitTesting(false)
        case .thinking:
            thoughtBubble(t: t)
        case .alert:
            Image(systemName: "shield.fill")
                .font(.system(size: size * 0.28, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF5A5A))
                .offset(x: size * 0.30, y: -size * 0.34)
                .allowsHitTesting(false)
        case .turbo:
            Image(systemName: "flame.fill")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: 0xFFC94D), Color(hex: 0xFF6A3D)],
                        startPoint: .top, endPoint: .bottom))
                .offset(x: size * 0.32, y: -size * 0.30)
                .scaleEffect(1 + 0.15 * abs(sin(t * 6)))
                .allowsHitTesting(false)
        case .worried:
            Ellipse()
                .fill(Neo.blue.opacity(0.85))
                .frame(width: size * 0.10, height: size * 0.16)
                .offset(x: size * 0.30, y: -size * 0.26)
                .rotationEffect(.degrees(-18))
                .allowsHitTesting(false)
        case .sad:
            Ellipse()
                .fill(Neo.blue.opacity(0.9))
                .frame(width: size * 0.11, height: size * 0.15)
                .offset(x: size * 0.28, y: -size * 0.16)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private func sparklePair(t: TimeInterval) -> some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.24, weight: .bold))
                .foregroundStyle(accent)
                .offset(x: size * 0.26, y: -size * 0.30)
                .opacity(0.45 + 0.55 * abs(sin(t * 3)))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.17, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .offset(x: -size * 0.22, y: size * 0.18)
                .opacity(0.35 + 0.65 * abs(cos(t * 2.6)))
        }
        .allowsHitTesting(false)
    }

    private func zzz(t: TimeInterval) -> some View {
        let drift = (t * 0.4).truncatingRemainder(dividingBy: 1)
        return ZStack {
            Text("z")
                .font(.system(size: size * 0.22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0xB39DDB))
                .offset(x: size * 0.30, y: -size * (0.30 + 0.12 * drift))
                .opacity(0.9 - 0.6 * drift)
            Text("Z")
                .font(.system(size: size * 0.16, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0xB39DDB).opacity(0.8))
                .offset(x: size * 0.46, y: -size * (0.44 + 0.12 * drift))
                .opacity(0.6 - 0.6 * drift)
        }
        .allowsHitTesting(false)
    }

    private func thoughtBubble(t: TimeInterval) -> some View {
        HStack(spacing: size * 0.045) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Neo.purple.opacity(0.9))
                    .frame(width: size * 0.055, height: size * 0.055)
                    .opacity(0.4 + 0.6 * abs(sin(t * 3 + Double(i) * 0.8)))
            }
        }
        .padding(.horizontal, size * 0.06)
        .padding(.vertical, size * 0.035)
        .background(Capsule().fill(.white.opacity(0.14)))
        .offset(x: size * 0.32, y: -size * 0.42)
        .allowsHitTesting(false)
    }

    private func confettiBurst(t: TimeInterval) -> some View {
        let colors: [Color] = [
            Neo.yellow, Color(hex: 0xFF9EB5), Neo.blue, Neo.green,
            Neo.purple, Color(hex: 0xFF8A3D),
        ]
        return ZStack {
            ForEach(0..<8, id: \.self) { i in
                let phase = (t * 1.4 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: size * 0.05, height: size * 0.05)
                    .offset(
                        x: -size * 0.45 + CGFloat(i % 4) * size * 0.28
                            + CGFloat(i % 2) * size * 0.05,
                        y: -size * 0.45 + phase * size * 0.55)
                    .opacity(1 - 0.7 * phase)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Drop zone

/// NSView that accepts link/magnet/text drags and reports clicks. Dragging
/// a URL out of a browser delivers `.URL`/`.string`; Finder files deliver
/// `.fileURL`.
struct NotchDropZone: NSViewRepresentable {
    var onGaze: (CGFloat) -> Void
    var onHover: (Bool) -> Void
    var onDropText: (String) -> Void
    var onDropFile: (URL) -> Void
    var onDragChange: (Bool) -> Void
    var onKey: (String) -> Void
    var wantKeyFocus: Bool

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        sync(view)
        return view
    }

    func updateNSView(_ nsView: DropCatcherView, context: Context) {
        sync(nsView)
    }

    private func sync(_ view: DropCatcherView) {
        view.onGaze = onGaze
        view.onHover = onHover
        view.onDropText = onDropText
        view.onDropFile = onDropFile
        view.onDragChange = onDragChange
        view.onKey = onKey
        if wantKeyFocus != view.hasFocusRequest {
            view.hasFocusRequest = wantKeyFocus
            DispatchQueue.main.async {
                if wantKeyFocus {
                    view.window?.makeFirstResponder(view)
                } else {
                    view.window?.makeFirstResponder(nil)
                }
            }
        }
    }
}

final class DropCatcherView: NSView {
    var onGaze: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDropText: ((String) -> Void)?
    var onDropFile: ((URL) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var onKey: ((String) -> Void)?
    var hasFocusRequest = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onKey?("esc")
        case 126: onKey?("up")
        case 125: onKey?("down")
        case 36, 76: onKey?("enter")
        default: super.keyDown(with: event)
        }
    }

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
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let x = (event.locationInWindow.x / bounds.width) * 2 - 1
        onGaze?(max(-1, min(1, x)))
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
