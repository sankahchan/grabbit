import Foundation
import Network

/// BEP 15 UDP tracker liveness probe (connect request only).
///
/// `trackers_best.txt` rots — dead trackers waste announce time on every
/// torrent. Like Motrix's tracker prober, this sends a UDP connect request
/// and keeps only trackers that answer, so the `--bt-tracker` list handed
/// to aria2 is live. Non-UDP announce URLs can't be cheaply probed and are
/// kept as-is.
enum TrackerProber {
    /// BEP 15 magic protocol ID for the connect request.
    private static let protocolID: UInt64 = 0x41727101980
    /// Connect action.
    private static let actionConnect: UInt32 = 0

    // MARK: - Pure packet helpers (unit-tested)

    /// Builds a 16-byte BEP 15 connect request. Byte-wise encoding —
    /// `UnsafeRawBufferPointer.load(as:)` requires aligned memory and
    /// Data's storage alignment isn't guaranteed.
    static func connectRequest(transactionID: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((protocolID >> shift) & 0xFF))
        }
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((actionConnect >> shift) & 0xFF))
        }
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((transactionID >> shift) & 0xFF))
        }
        return data
    }

    /// Parses a connect response; returns the echoed transaction ID, or nil
    /// when the packet isn't a valid connect response.
    static func parseConnectResponse(_ data: Data) -> UInt32? {
        guard data.count >= 16 else { return nil }
        func u32(at offset: Int) -> UInt32 {
            let i = data.startIndex + offset
            return (UInt32(data[i]) << 24)
                | (UInt32(data[i + 1]) << 16)
                | (UInt32(data[i + 2]) << 8)
                | UInt32(data[i + 3])
        }
        guard u32(at: 0) == actionConnect else { return nil }
        return u32(at: 4)
    }

    /// Extracts the (host, port) for a `udp://` announce URL, or nil when
    /// the URL isn't a UDP tracker with an explicit port.
    static func udpEndpoint(for announceURL: String) -> (host: String, port: UInt16)? {
        guard let url = URL(string: announceURL),
              url.scheme?.lowercased() == "udp",
              let host = url.host, !host.isEmpty,
              let port = url.port, port > 0, port <= 65535
        else { return nil }
        return (host, UInt16(port))
    }

    // MARK: - Network probe

    /// Returns the subset of `trackers` that answered a UDP connect request
    /// within `timeout`, preserving list order. Non-UDP trackers are kept
    /// unconditionally (not probeable). Bounded concurrency keeps the
    /// whole pass to roughly `timeout` even for long lists.
    ///
    /// The refill logic is inline (no nested function): a local `func`
    /// capturing the task group's inout binding plus the mutable counters
    /// trips Swift's capture rules, so the priming loop is duplicated
    /// instead.
    static func probe(
        _ trackers: [String],
        timeout: TimeInterval = 2,
        maxConcurrent: Int = 20
    ) async -> [String] {
        var healthy = [Bool](repeating: false, count: trackers.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var pending = trackers.indices.makeIterator()
            var inFlight = 0
            // Prime.
            while inFlight < maxConcurrent, let i = pending.next() {
                if udpEndpoint(for: trackers[i]) == nil {
                    healthy[i] = true
                } else {
                    inFlight += 1
                    group.addTask { (i, await probeOne(trackers[i], timeout: timeout)) }
                }
            }
            // Refill as each probe settles.
            for await (i, ok) in group {
                healthy[i] = ok
                inFlight -= 1
                while inFlight < maxConcurrent, let j = pending.next() {
                    if udpEndpoint(for: trackers[j]) == nil {
                        healthy[j] = true
                    } else {
                        inFlight += 1
                        group.addTask { (j, await probeOne(trackers[j], timeout: timeout)) }
                    }
                }
            }
        }
        return trackers.indices.filter { healthy[$0] }.map { trackers[$0] }
    }

    private static func probeOne(_ tracker: String, timeout: TimeInterval) async -> Bool {
        guard let (host, port) = udpEndpoint(for: tracker),
              let nwPort = NWEndpoint.Port(rawValue: port)
        else { return false }
        let txID = UInt32.random(in: 0...UInt32.max)
        let request = connectRequest(transactionID: txID)
        return await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "com.sankahchan.grabbit.tracker-probe")
            let conn = NWConnection(
                host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            var finished = false
            func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: request, completion: .contentProcessed { _ in
                        conn.receiveMessage { data, _, _, _ in
                            if let data, parseConnectResponse(data) == txID {
                                finish(true)
                            } else {
                                finish(false)
                            }
                        }
                    })
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            conn.start(queue: queue)
        }
    }
}
