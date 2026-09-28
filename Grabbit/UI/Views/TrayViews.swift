import AppKit

/// Weak handle to the main window, captured by WindowFrameSaver.
/// Tray mode uses it to show the window from the menu bar.
enum MainWindowHolder {
    static weak var window: NSWindow?
}

/// Combined live download speed across the direct-download and torrent
/// engines. Media downloads are short-lived yt-dlp runs without a
/// per-second speed signal, so they are not counted.
/// @MainActor because TorrentEngine's state is main-actor-isolated.
@MainActor
func trayTotalSpeed(downloads: DownloadEngine, torrents: TorrentEngine) -> Double {
    let direct = downloads.items
        .filter { $0.state == .downloading }
        .reduce(0.0) { $0 + $1.speedBytesPerSec }
    let torrent = torrents.torrents
        .filter { $0.state == .downloading }
        .reduce(0.0) { $0 + Double($1.downloadSpeed) }
    return direct + torrent
}

/// AppKit menu-bar extra for tray mode: live speed in the menu bar,
/// dropdown menu with speed header, Open Grabbit, Quit.
///
/// Built on NSStatusItem directly: SwiftUI's MenuBarExtra scene crashed
/// the compiler when inserted conditionally into the SceneBuilder
/// (dca6ea9), and the status item gives precise show/hide control.
/// All methods must run on the main thread.
final class TrayController {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private weak var downloads: DownloadEngine?
    private weak var torrents: TorrentEngine?
    private var speedItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var quitItem: NSMenuItem?

    func configure(downloads: DownloadEngine, torrents: TorrentEngine) {
        self.downloads = downloads
        self.torrents = torrents
    }

    /// Show or hide the menu bar icon. Safe to call repeatedly.
    func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = Self.trayIcon()
            }
            let menu = NSMenu()
            // Disabled header item showing the live total speed.
            let speed = NSMenuItem(title: "Grabbit", action: nil, keyEquivalent: "")
            menu.addItem(speed)
            speedItem = speed
            menu.addItem(.separator())
            let open = NSMenuItem(title: "", action: #selector(openMainWindow), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            openItem = open
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            quitItem = quit
            item.menu = menu
            statusItem = item
            timer = Timer.scheduledTimer(
                timeInterval: 1.0, target: self,
                selector: #selector(fireTimer), userInfo: nil, repeats: true)
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            speedItem = nil
            openItem = nil
            quitItem = nil
        }
    }

    private static func trayIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "Grabbit")
        image?.isTemplate = true
        return image
    }

    @objc private func fireTimer() {
        refresh()
    }

    /// Bounce through the main actor: the engines' state is
    /// @MainActor-isolated, while the timer/NSStatusItem side stays
    /// plain main-thread code.
    private func refresh() {
        Task { @MainActor [weak self] in
            self?.refreshOnMain()
        }
    }

    @MainActor
    private func refreshOnMain() {
        // Live speed readout. Also re-resolves the menu titles, so an
        // in-app language switch applies without recreating the menu.
        guard let downloads, let torrents else { return }
        let total = trayTotalSpeed(downloads: downloads, torrents: torrents)
        if let button = statusItem?.button {
            if total > 0 {
                button.title = "↓ \(formatSpeed(total))"
                button.image = nil
            } else {
                button.title = ""
                button.image = Self.trayIcon()
            }
        }
        speedItem?.title = total > 0 ? "↓ \(formatSpeed(total))" : "Grabbit"
        openItem?.title = NSLocalizedString("tray.open", comment: "")
        quitItem?.title = NSLocalizedString("tray.quit", comment: "")
    }

    @objc private func openMainWindow() {
        MainWindowHolder.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
