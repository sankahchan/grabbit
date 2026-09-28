import SwiftUI

// MARK: - Backlog #3: per-host profiles

/// Downloads-card section listing saved per-host profiles (credentials, thread
/// count, user-agent). Applied automatically by DownloadEngine.add when a
/// download URL's host matches.
struct HostProfilesSection: View {
    @Environment(HostProfileStore.self) private var store
    @State private var editTarget: HostProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            subHeader(NSLocalizedString("settings.hostProfiles.title", comment: ""))
            Text(NSLocalizedString("settings.hostProfiles.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.profiles) { profile in
                profileRow(profile)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("settings.hostProfiles.add", comment: "")) {
                    editTarget = HostProfile()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            }
        }
        .sheet(item: $editTarget) { target in
            HostProfileEditSheet(initial: target) { saved in
                if store.profiles.contains(where: { $0.id == saved.id }) {
                    store.update(saved)
                } else {
                    store.add(saved)
                }
            }
        }
    }

    private func profileRow(_ profile: HostProfile) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { profile.isEnabled },
                set: { store.setEnabled(id: profile.id, enabled: $0) }
            ))
            .toggleStyle(NeoToggleStyle())
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.host.isEmpty
                    ? NSLocalizedString("settings.hostProfiles.hostPlaceholder", comment: "")
                    : profile.host)
                    .font(.headline)
                Text(summary(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editTarget = profile
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            Button {
                store.remove(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
        }
        .padding(.vertical, 4)
    }

    private func summary(for profile: HostProfile) -> String {
        var parts: [String] = []
        if profile.username.isEmpty {
            parts.append(NSLocalizedString("settings.hostProfiles.noAuth", comment: ""))
        } else {
            parts.append(profile.username)
        }
        if let n = profile.maxConnections {
            parts.append("\(n) " + NSLocalizedString("settings.hostProfiles.connections", comment: ""))
        } else {
            parts.append(NSLocalizedString("settings.hostProfiles.connectionsAuto", comment: ""))
        }
        if !profile.userAgent.isEmpty {
            parts.append(NSLocalizedString("settings.hostProfiles.customUA", comment: ""))
        }
        return parts.joined(separator: " • ")
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.heavy))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct HostProfileEditSheet: View {
    let initial: HostProfile
    var onSave: (HostProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var host: String
    @State private var username: String
    @State private var password: String
    @State private var useCustomConnections: Bool
    @State private var connections: Int
    @State private var userAgent: String

    init(initial: HostProfile, onSave: @escaping (HostProfile) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _host = State(initialValue: initial.host)
        _username = State(initialValue: initial.username)
        _password = State(initialValue: initial.password)
        _useCustomConnections = State(initialValue: initial.maxConnections != nil)
        _connections = State(initialValue: initial.maxConnections ?? 8)
        _userAgent = State(initialValue: initial.userAgent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("settings.hostProfiles.title", comment: ""))
                .font(.title2.weight(.heavy))
            labeled(NSLocalizedString("settings.hostProfiles.host", comment: "")) {
                TextField(
                    NSLocalizedString("settings.hostProfiles.hostPlaceholder", comment: ""),
                    text: $host)
                .textFieldStyle(.roundedBorder)
            }
            labeled(NSLocalizedString("settings.hostProfiles.username", comment: "")) {
                TextField("", text: $username)
                    .textFieldStyle(.roundedBorder)
            }
            labeled(NSLocalizedString("settings.hostProfiles.password", comment: "")) {
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(NSLocalizedString("settings.hostProfiles.connections", comment: ""),
                   isOn: $useCustomConnections)
            .toggleStyle(NeoToggleStyle())
            if useCustomConnections {
                NeoStepper(value: $connections, in: 1...32, step: 1) { "\($0)" }
            }
            labeled(NSLocalizedString("settings.hostProfiles.userAgent", comment: "")) {
                TextField(
                    NSLocalizedString("settings.hostProfiles.userAgentPlaceholder", comment: ""),
                    text: $userAgent)
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Button(NSLocalizedString("common.save", comment: "")) {
                    var saved = initial
                    saved.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.username = username
                    saved.password = password
                    saved.maxConnections = useCustomConnections ? connections : nil
                    saved.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

// MARK: - Backlog #4: packagizer-style rules

/// Downloads-card section listing regex download rules (rename template and/or
/// category override). The first enabled rule matching a URL applies at
/// add time.
struct PackagizerRulesSection: View {
    @Environment(PackagizerStore.self) private var store
    @State private var editTarget: PackagizerRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            subHeader(NSLocalizedString("settings.packagizer.title", comment: ""))
            Text(NSLocalizedString("settings.packagizer.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.rules) { rule in
                ruleRow(rule)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("settings.packagizer.add", comment: "")) {
                    editTarget = PackagizerRule()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
            }
        }
        .sheet(item: $editTarget) { target in
            PackagizerRuleEditSheet(initial: target) { saved in
                if store.rules.contains(where: { $0.id == saved.id }) {
                    store.update(saved)
                } else {
                    store.add(saved)
                }
            }
        }
    }

    private func ruleRow(_ rule: PackagizerRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { store.setEnabled(id: rule.id, enabled: $0) }
            ))
            .toggleStyle(NeoToggleStyle())
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty
                    ? NSLocalizedString("settings.packagizer.namePlaceholder", comment: "")
                    : rule.name)
                    .font(.headline)
                Text(summary(for: rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                editTarget = rule
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.blue, compact: true))
            Button {
                store.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(NeoButtonStyle(bg: Neo.red, compact: true))
        }
        .padding(.vertical, 4)
    }

    private func summary(for rule: PackagizerRule) -> String {
        var parts: [String] = [rule.urlPattern]
        if !rule.filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("→ \(rule.filenameTemplate)")
        }
        if let category = rule.category {
            parts.append(category.localizedName)
        }
        return parts.joined(separator: " • ")
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.heavy))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct PackagizerRuleEditSheet: View {
    let initial: PackagizerRule
    var onSave: (PackagizerRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var name: String
    @State private var urlPattern: String
    @State private var filenameTemplate: String
    @State private var category: DownloadCategory?

    init(initial: PackagizerRule, onSave: @escaping (PackagizerRule) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial.name)
        _urlPattern = State(initialValue: initial.urlPattern)
        _filenameTemplate = State(initialValue: initial.filenameTemplate)
        _category = State(initialValue: initial.category)
    }

    private var patternValid: Bool {
        let trimmed = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: trimmed)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("settings.packagizer.title", comment: ""))
                .font(.title2.weight(.heavy))
            labeled(NSLocalizedString("settings.packagizer.name", comment: "")) {
                TextField(
                    NSLocalizedString("settings.packagizer.namePlaceholder", comment: ""),
                    text: $name)
                .textFieldStyle(.roundedBorder)
            }
            labeled(NSLocalizedString("settings.packagizer.pattern", comment: "")) {
                TextField(
                    NSLocalizedString("settings.packagizer.patternPlaceholder", comment: ""),
                    text: $urlPattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }
            if !patternValid {
                Text(NSLocalizedString("settings.packagizer.patternInvalid", comment: ""))
                    .font(.caption)
                    .foregroundStyle(Neo.red)
            }
            labeled(NSLocalizedString("settings.packagizer.template", comment: "")) {
                TextField("{name}.{ext}", text: $filenameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Text(NSLocalizedString("settings.packagizer.templateHint", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            labeled(NSLocalizedString("settings.packagizer.category", comment: "")) {
                Picker("", selection: $category) {
                    Text(NSLocalizedString("settings.packagizer.categoryAuto", comment: ""))
                        .tag(nil as DownloadCategory?)
                    ForEach(DownloadCategory.allCases, id: \.self) { c in
                        Text(c.localizedName).tag(c as DownloadCategory?)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.paper(scheme), compact: true))
                Button(NSLocalizedString("common.save", comment: "")) {
                    var saved = initial
                    saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.urlPattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.filenameTemplate = filenameTemplate.trimmingCharacters(in: .whitespaces)
                    saved.category = category
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green, compact: true))
                .disabled(!patternValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}
