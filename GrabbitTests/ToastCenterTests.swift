import Foundation
import XCTest
@testable import Grabbit

/// ToastCenter: push caps, manual dismiss, auto-dismiss, and the
/// main-thread hop for background callers (e.g. the torrent poll loop).
final class ToastCenterTests: XCTestCase {
    private func makeToast(
        kind: ToastKind = .completed,
        source: ToastSource = .download
    ) -> AppToast {
        AppToast(kind: kind, source: source, title: "t", message: "m")
    }

    func testPushAppendsToast() {
        let center = ToastCenter()
        center.push(makeToast())
        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts.first?.kind, .completed)
    }

    func testPushEvictsOldestAtCap() {
        let center = ToastCenter(maxToasts: 2)
        let first = makeToast()
        center.push(first)
        center.push(makeToast())
        center.push(makeToast())
        XCTAssertEqual(center.toasts.count, 2)
        XCTAssertFalse(center.toasts.contains(where: { $0.id == first.id }))
    }

    func testDismissRemovesToast() {
        let center = ToastCenter()
        let toast = makeToast()
        center.push(toast)
        center.dismiss(id: toast.id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testDismissUnknownIDIsNoop() {
        let center = ToastCenter()
        center.push(makeToast())
        center.dismiss(id: UUID())
        XCTAssertEqual(center.toasts.count, 1)
    }

    /// Async test methods run off-main by default; @MainActor keeps
    /// push/dismiss synchronous so the assertions are deterministic.
    @MainActor
    func testAutoDismiss() async throws {
        let center = ToastCenter(dismissAfter: 0.05)
        center.push(makeToast())
        XCTAssertEqual(center.toasts.count, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    @MainActor
    func testManualDismissCancelsAutoDismiss() async throws {
        let center = ToastCenter(dismissAfter: 0.05)
        let toast = makeToast()
        center.push(toast)
        center.dismiss(id: toast.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    /// The torrent poll loop runs off-main; push must still land the
    /// toast without tripping @Observable's main-thread expectation.
    func testPushFromBackgroundThread() async throws {
        let center = ToastCenter()
        let toast = makeToast()
        await Task.detached { center.push(toast) }.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(center.toasts.count, 1)
    }
}
