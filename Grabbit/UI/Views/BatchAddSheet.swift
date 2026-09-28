import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

/// Backlog #5: per-link overrides in the batch-add sheet. Empty filename
/// = auto, nil category/connections = the shared values above.
private struct BatchCustom: Hashable {
    var filename: String = ""
    var category: DownloadCategory? = nil
    var connections: Int? = nil
}

/// Where a batch goes: straight to Downloads, or into the LinkGrabber
/// staging area for check-then-commit.
private enum BatchDestination: Hashable {
    case downloads, linkGrabber
}

/// Phase 5 batch add: paste many links (one per line) and add them all at
/// once with shared category / queue / connection settings. Per-item
/// customization and text-file import arrive post-Phase-5 (backlog #5).
struct BatchAddSheet: View {
    @Environment(DownloadEngine.self) private var engine: DownloadEngine
    @Environment(QueueStore.self) private var queueStore: QueueStore
    @Environment(LinkGrabberStore.self) private var linkGrabberStore: LinkGrabberStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var text = ""
    @State private var category: DownloadCategory = .other
    @State private var queueID: UUID? = nil
    @State private var connections: Int = 8
    @State private var destination: BatchDestination = .downloads
    @State private var packageName = ""
    @State private var isAdding = false
    /// Backlog #5: per-link overrides, keyed by URL string.
    @State private var customs: [String: BatchCustom] = [:]
    /// The in-flight batch, so Cancel can stop it (the current probe
    /// finishes its timeout at the latest). Already-added links stay as
    /// real downloads; the rest are never added.
    @State private var addTask: Task<Void, Never>?

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
                    Button(NSLocalizedString("batch.import", comment: "")) {
                        importTextFile()
                    }
                    .buttonStyle(NeoButtonStyle(bg: Neo.purple, compact: true))
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

            // MARK: Backlog #5 — per-link customization
            if !links.isEmpty && destination == .downloads {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("batch.perItem", comment: ""))
                        .font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(links, id: \.self) { url in
                                BatchItemRow(
                                    url: url,
                                    sharedConnections: connections,
                                    custom: customBinding(for: url))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
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

            // MARK: Destination
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("batch.destination", comment: ""))
                    .font(.headline)
                NeoSegmented(selection: $destination, titles: [
                    (.downloads, NSLocalizedString("batch.destination.downloads", comment: "")),
                    (.linkGrabber, NSLocalizedString("batch.destination.linkgrabber", comment: "")),
                ])
                if destination == .linkGrabber {
                    TextField(
                        NSLocalizedString("linkgrabber.packageName", comment: ""),
                        text: $packageName
                    )
                    .neoTextField()
                }
            }

            // MARK: Add
            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    cancel()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Spacer()
                if isAdding { ProgressView().controlSize(.small) }
                Button(destination == .downloads
                    ? String(format: NSLocalizedString("batch.add", comment: ""), links.count)
                    : String(format: NSLocalizedString("batch.stage", comment: ""), links.count)
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
        // Staging needs no per-link probing here — the LinkGrabber store
        // probes each link itself as it lands in the package.
        if destination == .linkGrabber {
            let name = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = String(
                format: NSLocalizedString("linkgrabber.package.defaultName", comment: ""),
                DateFormatter.localizedString(
                    from: Date(), dateStyle: .short, timeStyle: .short))
            linkGrabberStore.stage(
                urls: urls,
                packageName: name.isEmpty ? fallback : name)
            dismiss()
            return
        }
        let category = category
        let queueID = queueID
        let connections = connections
        let customs = customs
        let engine = engine
        isAdding = true
        addTask = Task {
            for url in urls {
                if Task.isCancelled { break }
                // Backlog #5: per-link overrides fall back to the shared
                // values; an empty filename means "auto".
                let custom = customs[url.absoluteString]
                let filename = custom?.filename
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await engine.add(
                    url: url,
                    filename: filename?.isEmpty == false ? filename : nil,
                    category: custom?.category ?? category,
                    connections: custom?.connections ?? connections,
                    queueID: queueID)
            }
            isAdding = false
            addTask = nil
            dismiss()
        }
    }

    /// Stops the in-flight batch (the current probe finishes its timeout
    /// at the latest) and closes the sheet. Links already added stay as
    /// real downloads.
    private func cancel() {
        addTask?.cancel()
        addTask = nil
        isAdding = false
        dismiss()
    }

    /// Backlog #5: binding to a link's per-link overrides (created lazily).
    private func customBinding(for url: URL) -> Binding<BatchCustom> {
        let key = url.absoluteString
        return Binding(
            get: { customs[key] ?? BatchCustom() },
            set: { customs[key] = $0 }
        )
    }

    /// Backlog #5: appends a .txt file's contents (one link per line) to
    /// the pasted links.
    private func importTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? content
            : text + "\n" + content
    }
}

/// Backlog #5: one row per link — filename, category, and connection
/// overrides. Untouched rows inherit the shared values above.
private struct BatchItemRow: View {
    let url: URL
    let sharedConnections: Int
    @Binding var custom: BatchCustom

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                TextField(
                    NSLocalizedString("batch.filenameAuto", comment: ""),
                    text: $custom.filename
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                Picker("", selection: $custom.category) {
                    Text(NSLocalizedString("batch.sharedValue", comment: ""))
                        .tag(nil as DownloadCategory?)
                    ForEach(DownloadCategory.allCases, id: \.self) { c in
                        Text(c.localizedName).tag(c as DownloadCategory?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 130)
                NeoStepper(value: Binding(
                    get: { custom.connections ?? sharedConnections },
                    set: { custom.connections = $0 }
                ), in: 1...16, step: 1) { v in "\(v)" }
            }
        }
        .padding(6)
        .neoCard()
    }
}
