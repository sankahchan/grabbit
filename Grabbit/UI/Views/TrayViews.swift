import SwiftUI
import AppKit

/// Weak handle to the main window, captured by WindowFrameSaver.
/// Tray mode uses it to show/hide the window from the menu bar.
enum MainWindowHolder {
    static weak var window: NSWindow?
}

/// Combined live download speed across the direct-download and torrent
/// engines. Media downloads are short-lived yt-dlp runs without a
/// per-second speed signal, so they are not counted.
private func trayTotalSpeed(
    downloads: DownloadEngine, torrents: TorrentEngine
) -> Double {
    let direct = downloads.items
        .filter { $0.state == .downloading }
        .reduce(0.0) { $0 + $1.speedBytesPerSec }
    let torrent = torrents.torrents
        .filter { $0.state == .downloading }
        .reduce(0.0) { $0 + Double($1.downloadSpeed) }
    return direct + torrent
}

/// Menu bar label in tray mode: live total speed while downloading,
/// the Grabbit arrow icon when idle.
struct TrayLabelView: View {
    @Environment(DownloadEngine.self) private var downloads
    @Environment(TorrentEngine.self) private var torrents

    var body: some View {
        let total = trayTotalSpeed(downloads: downloads, torrents: torrents)
        if total > 0 {
            Text("↓ \(formatSpeed(total))")
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

/// Menu bar dropdown in tray mode: live speed header, Open, Quit.
struct TrayMenuView: View {
    @Environment(DownloadEngine.self) private var downloads
    @Environment(TorrentEngine.self) private var torrents

    var body: some View {
        let total = trayTotalSpeed(downloads: downloads, torrents: torrents)
        if total > 0 {
            Text("↓ \(formatSpeed(total))")
        } else {
            Text("Grabbit")
        }
        Divider()
        Button(NSLocalizedString("tray.open", comment: "")) {
            MainWindowHolder.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(NSLocalizedString("tray.quit", comment: "")) {
            NSApp.terminate(nil)
        }
    }
}
