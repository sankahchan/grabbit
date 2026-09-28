import AppKit
import Foundation
import Observation

/// Where a toast came from — the retry action routes back to the right engine.
public enum ToastSource: Sendable {
    case download
    case torrent
}

public enum ToastKind: Sendable {
    case completed
    case failed
}

/// An in-app completion/failure card (bottom-right overlay). Unlike the
/// system notification, it carries action buttons (Open File / Open Folder /
/// Try Again) and appears even when Grabbit is frontmost.
public struct AppToast: Identifiable, Sendable {
    public let id: UUID
    public let kind: ToastKind
    public let source: ToastSource
    public let title: String
    public let message: String
    /// Completed: the finished file (or torrent folder) to open/reveal.
    public let fileURL: URL?
    /// Failed: the task to retry.
    public let taskID: UUID?

    public init(
        id: UUID = UUID(),
        kind: ToastKind,
        source: ToastSource,
        title: String,
        message: String,
        fileURL: URL? = nil,
        taskID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.message = message
        self.fileURL = fileURL
        self.taskID = taskID
    }
}

/// Holds the visible toast cards. `@Observable` without class-level
/// `@MainActor` (store convention — views read it synchronously); `push`
/// and `dismiss` hop to the main thread when called from a background
/// context (e.g. the torrent poll loop) so `@Observable` notifications
/// always fire on main.
@Observable
public final class ToastCenter {
    public private(set) var toasts: [AppToast] = []

    private let maxToasts: Int
    private let dismissAfter: TimeInterval
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init(maxToasts: Int = 3, dismissAfter: TimeInterval = 8) {
        self.maxToasts = maxToasts
        self.dismissAfter = dismissAfter
    }

    public func push(_ toast: AppToast) {
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in self?.push(toast) }
            return
        }
        pushNow(toast)
    }

    private func pushNow(_ toast: AppToast) {
        if toasts.count >= maxToasts, let oldest = toasts.first {
            dismiss(id: oldest.id)
        }
        toasts.append(toast)
        let id = toast.id
        let delay = dismissAfter
        dismissTasks[id]?.cancel()
        dismissTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    public func dismiss(id: UUID) {
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in self?.dismiss(id: id) }
            return
        }
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }

    /// Subtle system alert sound — no bundled assets needed.
    /// Safe to call off-main (the torrent poll loop does).
    public static func playSound(for kind: ToastKind) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { playSound(for: kind) }
            return
        }
        let name: String
        switch kind {
        case .completed: name = "Glass"
        case .failed: name = "Basso"
        }
        NSSound(named: name)?.play()
    }
}
