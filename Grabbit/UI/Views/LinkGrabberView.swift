import SwiftUI

/// LinkGrabber-style staging tab (backlog #1, JDownloader-inspired): links
/// wait here while they are probed (online/offline + size) so the user can
/// inspect, rename and select them before committing as real downloads.
///
/// Ideas only — no JDownloader (GPL-3.0) source is used or copied.
struct LinkGrabberView: View {
    @Environment(LinkGrabberStore.self) private var store: LinkGrabberStore
    @Environment(\.colorScheme) private var scheme

    @State private var newPackageName = ""
    @State private var showingNewPackage = false
    @State private var isCommitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeoPageHeader(
                sticker: NSLocalizedString("page.linkgrabber.sticker", comment: ""),
                title: NSLocalizedString("nav.linkgrabber", comment: ""),
                accent: Neo.green)
            header
            if store.packages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.packages) { package in
                            packageCard(package)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(16)
        .navigationTitle(NSLocalizedString("nav.linkgrabber", comment: ""))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(NSLocalizedString("linkgrabber.subtitle", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
            Button(NSLocalizedString("linkgrabber.newPackage", comment: "")) {
                showingNewPackage = true
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
        }
        .sheet(isPresented: $showingNewPackage) {
            newPackageSheet
        }
    }

    private var newPackageSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("linkgrabber.newPackage", comment: ""))
                .font(NeoFont.f(.title3, .heavy))
            TextField(
                NSLocalizedString("linkgrabber.packageName", comment: ""),
                text: $newPackageName
            )
            .neoTextField()
            .onSubmit(createPackage)
            HStack {
                Spacer()
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    showingNewPackage = false
                    newPackageName = ""
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Button(NSLocalizedString("common.create", comment: "")) {
                    createPackage()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(newPackageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func createPackage() {
        let name = newPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createPackage(name: name)
        showingNewPackage = false
        newPackageName = ""
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            AppIcon("link", size: 14)
                .font(NeoFont.f(40))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("linkgrabber.empty.title", comment: ""))
                .font(NeoFont.f(.headline))
            Text(NSLocalizedString("linkgrabber.empty.hint", comment: ""))
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Package card

    private func packageCard(_ package: LinkPackage) -> some View {
        let staged = store.links(in: package.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(
                    NSLocalizedString("linkgrabber.packageName", comment: ""),
                    text: Binding(
                        get: { package.name },
                        set: { store.renamePackage(package.id, to: $0) }
                    )
                )
                .neoTextField()
                .font(NeoFont.f(.headline))
                Text(String(
                    format: NSLocalizedString("linkgrabber.links.count", comment: ""),
                    staged.count
                ))
                .font(NeoFont.f(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Neo.paper(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Button(NSLocalizedString("linkgrabber.downloadPackage", comment: "")) {
                    commit(ids: staged.map(\.id))
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(staged.allSatisfy { $0.status == .duplicate })
                Button(role: .destructive) {
                    store.removePackage(package.id)
                } label: {
                    AppIcon("trash", size: 14)
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
            }
            ForEach(staged) { link in
                linkRow(link)
            }
        }
        .neoCard(accent: Neo.green)
    }

    // MARK: - Link row

    private func linkRow(_ link: StagedLink) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { link.selected },
                set: { store.setSelected($0, for: link.id) }
            ))
            .toggleStyle(NeoToggleStyle())
            .disabled(link.status == .duplicate)

            statusIcon(for: link.status)

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    NSLocalizedString("linkgrabber.filename", comment: ""),
                    text: Binding(
                        get: { link.filename },
                        set: { store.setFilename($0, for: link.id) }
                    )
                )
                .neoTextField()
                .font(NeoFont.f(.body))
                HStack(spacing: 6) {
                    Text(link.url.absoluteString)
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let total = link.totalBytes {
                        Text("• \(formatBytes(total))")
                            .font(NeoFont.f(.caption))
                            .foregroundStyle(.secondary)
                    } else if link.status == .online {
                        Text("• \(NSLocalizedString("linkgrabber.sizeUnknown", comment: ""))")
                            .font(NeoFont.f(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                store.remove(ids: [link.id])
            } label: {
                AppIcon("xmark", size: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func statusIcon(for status: StagedLinkStatus) -> some View {
        Group {
            switch status {
            case .checking:
                NeoSpinner(size: 14)
                    .help(NSLocalizedString("linkgrabber.status.checking", comment: ""))
            case .online:
                AppIcon("checkmark.circle.fill", size: 14)
                    .foregroundStyle(Neo.green)
                    .help(NSLocalizedString("linkgrabber.status.online", comment: ""))
            case .offline:
                AppIcon("xmark.circle.fill", size: 14)
                    .foregroundStyle(Neo.red)
                    .help(NSLocalizedString("linkgrabber.status.offline", comment: ""))
            case .duplicate:
                AppIcon("doc.badge.plus", size: 14)
                    .foregroundStyle(Neo.orange)
                    .help(NSLocalizedString("linkgrabber.status.duplicate", comment: ""))
            }
        }
        .font(NeoFont.f(.title3))
        .frame(width: 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(NSLocalizedString("linkgrabber.selectAll", comment: "")) {
                store.setAllSelected(true)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            Button(NSLocalizedString("linkgrabber.selectNone", comment: "")) {
                store.setAllSelected(false)
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
            Spacer()
            if isCommitting { NeoSpinner(size: 16) }
            Button(role: .destructive) {
                store.remove(ids: store.links.filter(\.selected).map(\.id))
            } label: {
                Text(NSLocalizedString("linkgrabber.removeSelected", comment: ""))
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
            .disabled(store.links.allSatisfy { !$0.selected })
            Button(String(
                format: NSLocalizedString("linkgrabber.downloadSelected", comment: ""),
                store.selectableCount
            )) {
                commit(ids: store.links.filter(\.selected).map(\.id))
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            .disabled(store.selectableCount == 0 || isCommitting)
        }
    }

    private func commit(ids: [UUID]) {
        isCommitting = true
        Task {
            await store.commit(ids: ids)
            isCommitting = false
        }
    }
}
