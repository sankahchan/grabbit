import SwiftUI

enum ScheduleAction: String, CaseIterable, Codable {
    case download, stop, speedLimit

    var localizedTitle: String {
        switch self {
        case .download: NSLocalizedString("scheduler.action.download", comment: "")
        case .stop: NSLocalizedString("scheduler.action.stop", comment: "")
        case .speedLimit: NSLocalizedString("scheduler.action.speedLimit", comment: "")
        }
    }
}

public struct ScheduleEntry: Identifiable, Codable {
    public var id: UUID = UUID()
    var time: Date
    var action: ScheduleAction
    var isEnabled: Bool = true
    /// Weekday bitmask: bit (weekday - 1), Calendar weekday 1 = Sunday …
    /// 7 = Saturday. `allWeekdays` = every day.
    var weekdays: Int = ScheduleEntry.allWeekdays
    /// Last fire date — an entry fires at most once per calendar day.
    var lastFired: Date? = nil
    /// Backlog #8: speed profiles — used when action == .speedLimit.
    /// Global cap in bytes/sec applied at fire time (0 = unlimited).
    var speedLimitBytesPerSec: Int64 = 0

    static let allWeekdays = 0b1111111
}

/// Scheduler tab: list of time-based entries (start downloads / stop all).
///
/// NOTE: entries live in `@State` for this UI scaffold. The real scheduler —
/// persisted entries plus actual timed triggers (launchd / background tasks) —
/// is future work.
struct SchedulerView: View {
    @Environment(SchedulerStore.self) private var scheduler
    @State private var showingAdd = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 12) {
            if !scheduler.entries.isEmpty {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("scheduler.add", comment: "")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
            }

            if scheduler.entries.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(scheduler.entries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .padding(12)
        .navigationTitle(NSLocalizedString("scheduler.title", comment: ""))
        .sheet(isPresented: $showingAdd) {
            AddScheduleSheet { entry in
                scheduler.add(entry)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(NSLocalizedString("scheduler.empty", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("scheduler.add", comment: "")) {
                showingAdd = true
            }
            .neoButton(bg: Neo.yellow)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Entry row

    private func entryRow(_ entry: ScheduleEntry) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { var updated = entry; updated.isEnabled = $0; scheduler.update(updated) }
            ))
            .labelsHidden()
            .toggleStyle(NeoToggleStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.time.formatted(date: .omitted, time: .shortened))
                    .font(.headline.weight(.bold))
                Text(actionSummary(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(weekdaySummary(for: entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                scheduler.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
        }
        .neoCard()
    }

    /// "Daily", or the system-localized short weekday names for the set bits.
    private func weekdaySummary(for entry: ScheduleEntry) -> String {
        if entry.weekdays == ScheduleEntry.allWeekdays {
            return NSLocalizedString("scheduler.daily", comment: "")
        }
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.indices
            .filter { entry.weekdays & (1 << $0) != 0 }
            .map { symbols[$0] }
            .joined(separator: ", ")
    }

    /// Backlog #8: speed-limit entries show their cap in the row.
    private func actionSummary(for entry: ScheduleEntry) -> String {
        guard entry.action == .speedLimit else {
            return entry.action.localizedTitle
        }
        let value = entry.speedLimitBytesPerSec <= 0
            ? NSLocalizedString("settings.unlimited", comment: "")
            : formatSpeed(Double(entry.speedLimitBytesPerSec))
        return "\(entry.action.localizedTitle): \(value)"
    }
}

// MARK: - Add entry sheet

private struct AddScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var time = Date()
    @State private var action: ScheduleAction = .download
    @State private var weekdays: Int = ScheduleEntry.allWeekdays
    /// Backlog #8: KB/s for the .speedLimit action (0 = unlimited).
    @State private var speedKBps: Int = 500

    var onSave: (ScheduleEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("scheduler.add", comment: ""))
                .font(.title2.weight(.heavy))

            DatePicker(
                NSLocalizedString("scheduler.time", comment: ""),
                selection: $time,
                displayedComponents: .hourAndMinute
            )

            NeoSegmented(selection: $action, titles: ScheduleAction.allCases.map {
                ($0, $0.localizedTitle)
            })

            // Backlog #8: speed-profile entries carry a KB/s cap.
            if action == .speedLimit {
                HStack {
                    Text(NSLocalizedString("scheduler.speedLimit", comment: ""))
                        .font(.headline)
                    Spacer()
                    NeoStepper(value: $speedKBps, in: 0...100_000, step: 50) { v in
                        v == 0
                            ? NSLocalizedString("settings.unlimited", comment: "")
                            : "\(v) KB/s"
                    }
                }
            }

            // Repeat on specific weekdays (system-localized short names).
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("scheduler.repeat", comment: ""))
                    .font(.headline)
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        let on = weekdays & (1 << day) != 0
                        Button(Calendar.current.shortWeekdaySymbols[day]) {
                            weekdays ^= (1 << day)
                        }
                        .buttonStyle(NeoButtonStyle(
                            bg: on ? Neo.yellow : Neo.paper(scheme),
                            compact: true
                        ))
                    }
                }
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(NSLocalizedString("common.save", comment: "")) {
                    // An entry with no weekdays would never fire; fall back
                    // to daily rather than saving a dead entry.
                    let days = weekdays == 0 ? ScheduleEntry.allWeekdays : weekdays
                    var entry = ScheduleEntry(time: time, action: action, weekdays: days)
                    if action == .speedLimit {
                        entry.speedLimitBytesPerSec = Int64(speedKBps) * 1_024
                    }
                    onSave(entry)
                    dismiss()
                }
                .neoButton(bg: Neo.green)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
