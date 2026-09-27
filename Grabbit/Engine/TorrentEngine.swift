import Foundation
import Observation

public protocol TorrentEngineProtocol: AnyObject {
    var torrents: [TorrentItem] { get }
    func add(magnetOrURL: String, savePath: URL) async throws
    func pause(_ id: UUID)
    func resume(_ id: UUID)
    func remove(_ id: UUID, deleteData: Bool)
}

// MARK: - Real integration path (DOCUMENTED STUB)
//
// This engine is intentionally a bookkeeping stub until libtorrent is wired.
// The real integration path is:
//
//   1. Add libtorrent as a git submodule (e.g. under ThirdParty/libtorrent)
//      and build it with CMake for arm64.
//   2. Add an Objective-C++ bridge at Grabbit/Engine/LibTorrent/LTSessionBridge.h
//      and LTSessionBridge.mm exposing a plain C API, roughly:
//        lt_session_create() -> handle
//        lt_session_add_magnet(handle, magnet_or_torrent_url, save_path) -> torrent id
//        lt_session_pause(handle, torrent_id) / lt_session_resume(...)
//        lt_session_remove(handle, torrent_id, delete_files)
//        lt_session_pop_alerts(handle) -> serialized alert batch
//        lt_session_save_resume(handle, torrent_id)
//   3. Run an alerts loop (DispatchSourceTimer, ~500ms): map libtorrent alerts
//      (state_update_alert, torrent_finished_alert, save_resume_data_alert,
//      torrent_error_alert, ...) onto TorrentItem fields (downloadedBytes,
//      seeds/peers, ratio, state).
//   4. Persist resume data: request save_resume_data every 60s and on
//      pause/shutdown; write each torrent's fastresume blob atomically to
//      ~/Library/Application Support/Grabbit/Torrents/<id>.fastresume
//      (temp file + rename on the same volume — crash-safe, same pattern as
//      ResumeStore), and re-add via the fastresume on launch for instant resume.
//   5. Enable DHT (routers: router.bittorrent.com, dht.transmissionbt.com) and
//      expose a sequential-download toggle for streaming-friendly fetching.
//
// Until then: add() only records the torrent as .paused, pause()/resume()/
// remove() only flip in-memory state, and NO bytes are ever reported as
// downloaded. Nothing here pretends to transfer data.

@Observable
public final class TorrentEngine: TorrentEngineProtocol {
    public private(set) var torrents: [TorrentItem] = []

    public init() {}

    public func add(magnetOrURL: String, savePath: URL) async throws {
        // STUB: record intent only. Real path: LTSessionBridge add_torrent with
        // the magnet URI; metadata (name/totalBytes) arrives via alerts.
        let name = URL(string: magnetOrURL)?.host ?? magnetOrURL
        let item = TorrentItem(
            name: name,
            magnetURI: magnetOrURL,
            state: .paused,
            savePath: savePath
        )
        torrents.append(item)
    }

    public func pause(_ id: UUID) {
        // STUB: real path: lt_session_pause(handle, torrent_id) + save_resume_data.
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        torrents[index].state = .paused
    }

    public func resume(_ id: UUID) {
        // STUB: real path: lt_session_resume(handle, torrent_id); progress then
        // flows from the alerts loop. No fake bytes are synthesized here.
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        torrents[index].state = .downloading
    }

    public func remove(_ id: UUID, deleteData: Bool) {
        // STUB: real path: lt_session_remove(handle, torrent_id, delete_files).
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        let item = torrents.remove(at: index)
        if deleteData {
            try? FileManager.default.removeItem(at: item.savePath)
        }
    }
}
