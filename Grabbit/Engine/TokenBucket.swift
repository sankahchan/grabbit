import Foundation

/// Virtual-time rate limiter behind the Phase 5 speed limiter.
///
/// Each `consume(n)` advances a shared virtual clock (`nextFree`) by
/// `n / rate`; the caller sleeps until the clock says its bytes are due.
/// Because every consumer — across segments and transports — advances the
/// *same* clock under one lock, concurrent consumers naturally stagger and
/// the aggregate never exceeds the rate. (The naive "sleep the deficit"
/// design fails here: parallel sleeps don't serialize, so N consumers get
/// N× the limit — the QDM per-segment trap in another form.)
///
/// Rate 0 (or negative) means unlimited: `consume` returns immediately.
/// A 1-second burst allowance absorbs TCP burstiness; idling longer than
/// that never accrues more credit. Lowering the rate rescales any already-
/// queued wait so the new limit bites immediately instead of coasting.
final class TokenBucket: @unchecked Sendable {
    /// Maximum burst credit, in seconds of the current rate.
    private static let burstSeconds: TimeInterval = 1.0

    private let lock = NSLock()
    /// Virtual time when the next byte may be consumed. May lag `now` by
    /// at most `burstSeconds` (the burst allowance).
    private var nextFree: Date
    private var _rate: Double
    private let now: () -> Date
    private let sleeper: (TimeInterval) -> Void

    /// - Parameter rate: bytes per second; 0 = unlimited.
    /// - Parameter now: clock source (injectable for tests).
    /// - Parameter sleeper: how to wait (injectable for tests).
    init(
        rate: Double = 0,
        now: @escaping () -> Date = Date.init,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        let t = now()
        self.now = now
        self.sleeper = sleeper
        self._rate = max(0, rate)
        // Full burst credit up front.
        self.nextFree = t.addingTimeInterval(-Self.burstSeconds)
    }

    /// Bytes per second; 0 = unlimited.
    var rate: Double {
        get { lock.withLock { _rate } }
        set {
            lock.withLock {
                let newRate = max(0, newValue)
                let current = now()
                if newRate == 0 {
                    // Unlimited: reset the clock so re-enabling the limit
                    // later starts from a full burst, not stale debt.
                    nextFree = current.addingTimeInterval(-Self.burstSeconds)
                } else if _rate > 0, nextFree > current {
                    // Rescale the already-queued wait to the new rate:
                    // bytes owed = wait × oldRate, new wait = bytes / newRate.
                    let wait = nextFree.timeIntervalSince(current)
                    nextFree = current.addingTimeInterval(wait * _rate / newRate)
                }
                _rate = newRate
            }
        }
    }

    /// Blocks until `bytes` fit the rate. No-op when unlimited or when
    /// `bytes <= 0`.
    ///
    /// Guava-SmoothBursty semantics, in seconds instead of permits: the
    /// virtual clock always advances by exactly `duration` per consume, so
    /// concurrent callers serialize through it. Burst credit
    /// (`now - nextFree`, capped at `burstSeconds`) is *spent* by free
    /// consumes, never bypassed.
    func consume(_ bytes: Int) {
        guard bytes > 0 else { return }
        var delay: TimeInterval = 0
        lock.withLock {
            guard _rate > 0 else { return }
            let current = now()
            // Resync: the clock may lag `now` by at most `burstSeconds`,
            // however long we've been idle (caps the burst credit).
            let earliest = current.addingTimeInterval(-Self.burstSeconds)
            if nextFree < earliest { nextFree = earliest }
            let duration = Double(bytes) / _rate
            let stored = min(Self.burstSeconds, max(0, current.timeIntervalSince(nextFree)))
            if stored >= duration {
                // Fully covered by burst credit: spend it.
                nextFree = nextFree.addingTimeInterval(duration)
            } else {
                delay = duration - stored
                // Invariant: nextFree advances by exactly `duration`
                // (now + delay == nextFree + duration here).
                nextFree = current.addingTimeInterval(delay)
            }
        }
        if delay > 0 {
            sleeper(delay)
        }
    }
}
