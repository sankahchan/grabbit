import Foundation

/// Token-bucket rate limiter behind the Phase 5 speed limiter.
///
/// `consume(_:)` blocks the calling thread until `bytes` fit inside the
/// configured rate, then deducts them. Blocking (rather than suspending)
/// is deliberate: it is called from SegmentTransport's serial queue, where
/// the sleep *is* the pacing mechanism — no reordering, no extra tasks.
///
/// Rate 0 (or negative) means unlimited: `consume` returns immediately.
/// Thread-safe via NSLock, so one bucket can be shared across segments
/// and transports. That shared-bucket design is what makes the *global*
/// cap hold regardless of connection count — the trap QDM fell into was
/// applying the limit per segment (8 segments = 8x the setting).
final class TokenBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Double
    private var lastRefill: Date
    private var _rate: Double
    private let now: () -> Date

    /// - Parameter rate: bytes per second; 0 = unlimited.
    /// - Parameter now: clock source (injectable for tests).
    init(rate: Double = 0, now: @escaping () -> Date = Date.init) {
        _rate = max(0, rate)
        tokens = Self.capacity(for: _rate)
        self.now = now
        lastRefill = now()
    }

    /// Bytes per second; 0 = unlimited. Lowering the rate clamps stored
    /// tokens to the new capacity so the new limit bites immediately
    /// instead of coasting on accumulated burst.
    var rate: Double {
        get { lock.withLock { _rate } }
        set {
            lock.withLock {
                _rate = max(0, newValue)
                tokens = min(tokens, Self.capacity(for: _rate))
            }
        }
    }

    /// One second of burst: absorbs TCP burstiness without letting a
    /// lowered limit coast. Floored at 64 KiB so tiny limits still make
    /// progress in reasonable chunk sizes.
    private static func capacity(for rate: Double) -> Double {
        max(rate, 64 * 1024)
    }

    private func refillLocked() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        lastRefill = current
        tokens = min(Self.capacity(for: _rate), tokens + elapsed * _rate)
    }

    /// Blocks the calling thread until `bytes` fit the rate, then deducts
    /// them. No-op when the rate is 0 (unlimited).
    func consume(_ bytes: Int) {
        guard bytes > 0 else { return }
        var delay: TimeInterval = 0
        lock.withLock {
            let rate = _rate
            guard rate > 0 else { return }
            refillLocked()
            let need = Double(bytes)
            if tokens >= need {
                tokens -= need
            } else {
                delay = (need - tokens) / rate
                tokens = 0
            }
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
    }
}
