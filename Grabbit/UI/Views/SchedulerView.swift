import SwiftUI

enum ScheduleAction: String, CaseIterable {
    case download, stop

    var localizedTitle: String {
        switch self {
        case .download: String(localized: "scheduler.action.download")
        case .stop: String(localized: "scheduler.action.stop")
        }
    }
}

struct ScheduleEntry: Identifiable {
    let id: UUID = UUID()
    var time: Date
    var action: ScheduleAction
    var isEnabled: Bool = true
}

/// Scheduler tab: list of time-based entries (start downloads / stop all).
///
/// NOTE: entries live in `@State` for this UI scaffold. The real scheduler —
/// persisted entries plus actual timed triggers (launchd / background tasks) —
/// is future work.
struct SchedulerView: View {
    @State private var entries: [ScheduleEntry] = []
    @State private var showingAdd = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 12) {
            if !entries.isEmpty {
                HStack {
                    Spacer()
                    Button(String(localized: "scheduler.add")) {
                        showingAdd = true
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
                }
            }

            if entries.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach($entries) { $entry in
                            entryRow($entry)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .padding(12)
        .navigationTitle(String(localized: "scheduler.title"))
        .sheet(isPresented: $showingAdd) {
            AddScheduleSheet { entry in
                entries.append(entry)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 52))
                .foregroundStyle(Neo.ink(scheme))
            Text(String(localized: "scheduler.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "scheduler.add")) {
                showingAdd = true
            }
            .neoButton(bg: Neo.yellow)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Entry row

    private func entryRow(_ entry: Binding<ScheduleEntry>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: entry.isEnabled)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.wrappedValue.time.formatted(date: .omitted, time: .shortened))
                    .font(.headline.weight(.bold))
                Text(entry.wrappedValue.action.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                entries.removeAll { $0.id == entry.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
        }
        .neoCard()
    }
}

// MARK: - Add entry sheet

private struct AddScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var time = Date()
    @State private var action: ScheduleAction = .download

    var onSave: (ScheduleEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "scheduler.add"))
                .font(.title2.weight(.heavy))

            DatePicker(
                String(localized: "scheduler.time"),
                selection: $time,
                displayedComponents: .hourAndMinute
            )

            Picker(String(localized: "scheduler.add"), selection: $action) {
                ForEach(ScheduleAction.allCases, id: \.self) { a in
                    Text(a.localizedTitle).tag(a)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                Button(String(localized: "common.save")) {
                    onSave(ScheduleEntry(time: time, action: action))
                    dismiss()
                }
                .neoButton(bg: Neo.green)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
