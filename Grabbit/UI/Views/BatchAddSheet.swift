import SwiftUI
import AppKit

/// Pure multi-link parser: one URL per line, http(s) only, de-duplicated.
/// Kept free of UI so it's unit-testable.
enum BatchLinkParser {
    static func parse(_ text: String) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, seen.insert(line).inserted,
                  let url = URL(string: line),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else { continue }
            out.append(url)
        }
        return out
    }

    /// Non-empty lines that didn't parse as URLs (for the "skipped" note).
    static func invalidCount(in text: String, parsed: [URL]) -> Int {
        let nonEmpty = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
        return max(0, nonEmpty - parsed.count)
    }
}

/// Phase 5 batch add: paste many links (one per line) and add them all at
/// once with shared category / queue / connection settings. Per-item
/// customization and text-file import arrive post-Phase-5 (backlog #5).
struct BatchAddSheet: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(QueueStore.self) private var queueStore: QueueStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var category: DownloadCategory = .other
    @State private var queueID: UUID? = nil
    @State private var connections: Int = 8
    @State private var isAdding = false

    private var links: [URL] { BatchLinkParser.parse(text) }
    private var skipped: Int { BatchLinkParser.invalidCount(in: text, parsed: links) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("batch.title", comment: ""))
                .font(.title2.weight(.heavy))

            // MARK: Links
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(NSLocalizedString("batch.links", comment: ""))
                        .font(.headline)
                    Spacer()
                    Button(NSLocalizedString("common.paste", comment: "")) {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            text = s
                        }
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
                }
                TextEditor(text: $text)
                    .neoTextField()
                    .frame(minHeight: 120)
                    .font(.body.monospaced())
                HStack {
                    Text(String(
                        format: NSLocalizedString("batch.found", comment: ""),
                        links.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if skipped > 0 {
                        Text(String(
                            format: NSLocalizedString("batch.skipped", comment: ""),
                            skipped))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Category
            NeoSegmented(selection: $category, titles: DownloadCategory.allCases.map {
                ($0, $0.localizedName)
            })

            // MARK: Queue + connections
            HStack {
                Text(NSLocalizedString("add.queue", comment: ""))
                    .font(.headline)
                Spacer()
                Picker("", selection: $queueID) {
                    Text(queueStore.defaultQueue.displayName)
                        .tag(nil as UUID?)
                    ForEach(queueStore.queues.filter { !$0.isDefault }) { queue in
                        Text(queue.displayName).tag(queue.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
            HStack {
                NeoStepper(value: $connections, in: 1...16, step: 1) { v in "\(v)" }
                Spacer()
            }

            // MARK: Add
            HStack {
                Spacer()
                if isAdding { ProgressView().controlSize(.small) }
                Button(String(
                    format: NSLocalizedString("batch.add", comment: ""),
                    links.count)
                ) {
                    addAll()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(links.isEmpty || isAdding)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func addAll() {
        let urls = links
        let category = category
        let queueID = queueID
        let connections = connections
        let engine = engine
        isAdding = true
        Task {
            for url in urls {
                await engine.add(
                    url: url,
                    category: category,
                    connections: connections,
                    queueID: queueID)
            }
            dismiss()
        }
    }
}
