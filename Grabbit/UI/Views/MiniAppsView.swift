import SwiftUI

/// Mini Apps is the home for focused, helper-backed tools. Telegram lives
/// here today; future mini apps slot into the same catalog without adding
/// more top-level sidebar rows.
struct MiniAppsView: View {
    @Environment(TelegramService.self) private var telegram
    @Environment(\.colorScheme) private var scheme

    @State private var openApp: MiniApp?

    var body: some View {
        Group {
            if let openApp {
                TelegramView(onBack: { self.openApp = nil })
                    .id(openApp)
            } else {
                catalog
            }
        }
        .navigationTitle(NSLocalizedString("nav.miniapps", comment: ""))
        .task { await telegram.bootstrap() }
    }

    // MARK: - Catalog

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            NeoPageHeader(
                sticker: NSLocalizedString("miniapps.sticker", comment: ""),
                title: NSLocalizedString("miniapps.title", comment: ""),
                accent: Neo.purple)

            Text(NSLocalizedString("miniapps.subtitle", comment: ""))
                .font(NeoFont.f(.body))
                .foregroundStyle(Neo.ink2(scheme))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                spacing: 14
            ) {
                telegramCard
                comingSoonCard
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var telegramCard: some View {
        Button {
            openApp = .telegram
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if ThemeRuntime.current == .classic {
                        StickerIcon(
                            asset: "StickerPaperPlane",
                            size: 50,
                            fallback: "paperplane.fill")
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Neo.purple)
                            ThemedIcon(asset: "IconTelegram", system: "paperplane.fill", size: 20)
                                .foregroundStyle(Neo.onAccent(Neo.purple, scheme: scheme))
                        }
                        .frame(width: 42, height: 42)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(NSLocalizedString("telegram.title", comment: ""))
                            .font(NeoFont.f(.headline, .heavy))
                            .foregroundStyle(Neo.ink(scheme))
                        Text(telegramCardSubtitle)
                            .font(NeoFont.f(.caption2))
                            .foregroundStyle(Neo.ink2(scheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(statusLabel)
                        .neoBadge(bg: statusTint)
                }

                Text(NSLocalizedString("miniapps.telegram.description", comment: ""))
                    .font(NeoFont.f(.caption))
                    .foregroundStyle(Neo.ink2(scheme))

                HStack(spacing: 6) {
                    Text(NSLocalizedString("miniapps.telegram.open", comment: ""))
                        .font(NeoFont.f(.caption, .bold))
                        .textCase(.uppercase)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Neo.purple)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .neoCard(accent: Neo.purple, inset: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var comingSoonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if ThemeRuntime.current == .classic {
                    StickerIcon(
                        asset: "StickerMiniApps",
                        size: 50,
                        fallback: "square.grid.2x2")
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Neo.ink3(scheme).opacity(0.16))
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Neo.ink2(scheme))
                    }
                    .frame(width: 42, height: 42)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("miniapps.comingSoon.title", comment: ""))
                        .font(NeoFont.f(.headline, .heavy))
                        .foregroundStyle(Neo.ink(scheme))
                }
                Spacer(minLength: 0)
            }

            Text(NSLocalizedString("miniapps.comingSoon.body", comment: ""))
                .font(NeoFont.f(.caption))
                .foregroundStyle(Neo.ink2(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: Neo.ink3(scheme), inset: 14)
        .opacity(0.9)
    }

    // MARK: - Status

    private var statusLabel: String {
        switch telegram.authState {
        case .ready:
            NSLocalizedString("telegram.status.connected", comment: "")
        case .unknown, .loggingIn:
            NSLocalizedString("telegram.status.checking", comment: "")
        case .needs2FA:
            NSLocalizedString("telegram.status.2fa", comment: "")
        case .failed:
            NSLocalizedString("telegram.status.error", comment: "")
        case .loggedOut:
            NSLocalizedString("telegram.status.offline", comment: "")
        }
    }

    private var statusTint: Color {
        switch telegram.authState {
        case .ready: Neo.green
        case .unknown, .loggingIn, .needs2FA: Neo.yellow
        case .failed: Neo.red
        case .loggedOut: Neo.ink3(scheme)
        }
    }

    private var telegramCardSubtitle: String {
        switch telegram.authState {
        case .ready:
            if telegram.chats.isEmpty {
                return NSLocalizedString("telegram.status.connected", comment: "")
            }
            return String(
                format: NSLocalizedString("miniapps.chats.format", comment: ""),
                telegram.chats.count)
        case .unknown:
            return NSLocalizedString("telegram.status.checking", comment: "")
        case .loggingIn:
            return NSLocalizedString("telegram.status.waiting", comment: "")
        case .needs2FA:
            return NSLocalizedString("telegram.status.2fa", comment: "")
        case .failed:
            return NSLocalizedString("telegram.status.error", comment: "")
        case .loggedOut:
            return NSLocalizedString("telegram.status.offline", comment: "")
        }
    }
}

private enum MiniApp: String, Identifiable, CaseIterable {
    case telegram
    var id: String { rawValue }
}
