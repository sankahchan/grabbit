import SwiftUI

/// Per-task proxy override picker, shared by the Add Download and Add
/// Torrent sheets (Motrix parity). Binds to a non-optional draft; the
/// caller stores `nil` (follow global) when `draft.scope == .global`.
struct TaskProxySection: View {
    @Binding var draft: TaskProxy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("taskProxy.title", comment: ""))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                NeoSegmented(selection: scope, titles: [
                    (TaskProxy.Scope.global, TaskProxy.Scope.global.localizedName),
                    (TaskProxy.Scope.none, TaskProxy.Scope.none.localizedName),
                    (TaskProxy.Scope.custom, TaskProxy.Scope.custom.localizedName),
                ])
                .frame(maxWidth: 300)
            }
            if draft.scope == .custom {
                HStack {
                    Text(NSLocalizedString("proxy.mode.http", comment: ""))
                        .font(.subheadline)
                        .frame(width: 90, alignment: .leading)
                    NeoSegmented(selection: mode, titles: [
                        (ProxyMode.http, NSLocalizedString("proxy.mode.http", comment: "")),
                        (ProxyMode.socks5, NSLocalizedString("proxy.mode.socks5", comment: "")),
                    ])
                    .frame(maxWidth: 220)
                    Spacer()
                }
                labeledRow(NSLocalizedString("proxy.host", comment: "")) {
                    TextField("", text: $draft.host)
                        .neoTextField()
                }
                HStack(spacing: 12) {
                    Text(NSLocalizedString("proxy.port", comment: ""))
                        .font(.subheadline)
                        .frame(width: 90, alignment: .leading)
                    NeoStepper(value: $draft.port, in: 1...65535, step: 1) { "\($0)" }
                    Spacer()
                }
                labeledRow(NSLocalizedString("proxy.username", comment: "")) {
                    TextField("", text: $draft.username)
                        .neoTextField()
                }
                labeledRow(NSLocalizedString("proxy.password", comment: "")) {
                    SecureField("", text: $draft.password)
                        .neoTextField()
                }
            }
        }
    }

    private var scope: Binding<TaskProxy.Scope> {
        Binding(
            get: { draft.scope },
            set: { draft.scope = $0 })
    }

    private var mode: Binding<ProxyMode> {
        Binding(
            get: { draft.mode == .socks5 ? .socks5 : .http },
            set: { draft.mode = $0 })
    }

    private func labeledRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer()
        }
    }
}
