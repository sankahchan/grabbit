import SwiftUI

/// RSS subscriptions tab: feed polling with keyword filters, auto-download
/// and per-feed status. Media enclosures go to the direct engine; page
/// links (video channels) go to yt-dlp.
struct RSSFeedsView: View {
    @Environment(RSSStore.self) private var store: RSSStore
    @Environment(RSSMonitor.self) private var monitor: RSSMonitor
    @Environment(\.colorScheme) private var scheme

    @State private var showingAdd = false
    @State private var newURL = ""
    @State private var feedToRemove: RSSFeed?
    @State private var checking: Set<UUID> = []

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeoPageHeader(
                sticker: NSLocalizedString("page.rss.sticker", comment: ""),
                title: "RSS",
                accent: Neo.orange)
            header
            if store.feeds.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.feeds) { feed in
                            feedCard(feed)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(16)
        .navigationTitle("RSS")
        .sheet(isPresented: $showingAdd) { addSheet }
        .alert(
            NSLocalizedString("rss.remove.title", comment: ""),
            isPresented: Binding(
                get: { feedToRemove != nil },
                set: { if !$0 { feedToRemove = nil } })
        ) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                if let feed = feedToRemove { store.remove(id: feed.id) }
                feedToRemove = nil
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                feedToRemove = nil
            }
        } message: {
            Text(feedToRemove?.displayTitle ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(NSLocalizedString("rss.subtitle", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
            Button(NSLocalizedString("rss.checkAll", comment: "")) {
                Task { await monitor.checkAll() }
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            Button(NSLocalizedString("rss.add", comment: "")) {
                newURL = ""
                showingAdd = true
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.yellow, compact: true))
        }
    }

    // MARK: - Feed card

    private func feedCard(_ feed: RSSFeed) -> some View {
        let live = binding(for: feed)
        let error = live.wrappedValue.lastError
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(live.wrappedValue.displayTitle)
                    .font(NeoFont.f(.headline, .bold))
                    .lineLimit(1)
                Text(URL(string: live.wrappedValue.url)?.host ?? "")
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if checking.contains(feed.id) {
                    NeoSpinner(size: 14)
                }
                Button {
                    Task {
                        checking.insert(feed.id)
                        await monitor.check(feedID: feed.id)
                        checking.remove(feed.id)
                    }
                } label: {
                    AppIcon("arrow.clockwise", size: 14)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.paper(scheme)))
                .help(NSLocalizedString("rss.checkNow", comment: ""))
                Button(role: .destructive) {
                    feedToRemove = feed
                } label: {
                    AppIcon("trash", size: 14)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.red))
            }

            Toggle(NSLocalizedString("rss.enabled", comment: ""), isOn: live.isEnabled)
                .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("rss.autoDownload", comment: ""), isOn: live.autoDownload)
                .toggleStyle(NeoToggleStyle())
            Toggle(NSLocalizedString("rss.latestOnly", comment: ""), isOn: live.latestOnly)
                .toggleStyle(NeoToggleStyle())

            TextField(NSLocalizedString("rss.keywords", comment: ""), text: live.keywordFilter)
                .neoTextField()

            statusLine(for: live.wrappedValue, error: error)
        }
        .neoCard(accent: live.wrappedValue.isEnabled ? Neo.orange : Neo.paper(scheme))
    }

    @ViewBuilder
    private func statusLine(for feed: RSSFeed, error: String?) -> some View {
        if let error, !error.isEmpty {
            Text(error)
                .font(NeoFont.f(.caption, .semibold))
                .foregroundStyle(Neo.red)
                .lineLimit(2)
        } else {
            HStack(spacing: 6) {
                Text("\(NSLocalizedString("rss.lastChecked", comment: "")):")
                if let date = feed.lastCheckedAt {
                    Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                } else {
                    Text(NSLocalizedString("rss.never", comment: ""))
                }
                Spacer()
            }
            .font(NeoFont.f(.caption))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("rss.add.title", comment: ""))
                .font(NeoFont.f(.title2, .heavy))
            TextField(
                NSLocalizedString("rss.add.placeholder", comment: ""),
                text: $newURL
            )
            .neoTextField()
            .onSubmit { addFeed() }
            HStack {
                Spacer()
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    showingAdd = false
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Button(NSLocalizedString("rss.add", comment: "")) { addFeed() }
                    .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                    .disabled(validURL == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    private var validURL: URL? {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func addFeed() {
        guard validURL != nil, let feed = store.add(url: newURL) else { return }
        showingAdd = false
        // The first check only records the current items as seen and
        // populates the feed title — nothing downloads yet.
        Task { await monitor.check(feedID: feed.id) }
    }

    private func binding(for feed: RSSFeed) -> Binding<RSSFeed> {
        Binding(
            get: { store.feeds.first(where: { $0.id == feed.id }) ?? feed },
            set: { store.update($0) })
    }
}
