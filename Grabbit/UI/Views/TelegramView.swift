import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Telegram mini app: a media workbench for the signed-in account.
///
/// Deliberately not a messenger clone — there is no permanent dialog list.
/// Pick a channel from a sheet, then work through a full-width media library
/// with in-app photo preview and video/audio playback. Network and session
/// work lives in the bundled Go helper; this view only renders service state.
struct TelegramView: View {
    @Environment(TelegramService.self) private var telegram
    @Environment(\.colorScheme) private var scheme

    /// When hosted by Mini Apps, shows a back affordance in the top bar.
    var onBack: (() -> Void)?

    @State private var selectedChat: TelegramChat?
    @State private var searchText = ""
    @State private var filter: TelegramMediaFilter = .all
    @State private var twoStepPassword = ""
    @State private var dialog: TelegramDialog?
    @State private var showChannelPicker = false
    @State private var channelSearch = ""
    @State private var previewTarget: PreviewTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero

            switch telegram.authState {
            case .unknown:
                loadingCard
            case .loggedOut, .loggingIn, .needs2FA, .failed:
                loginCard
            case .ready:
                workbench
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await telegram.bootstrap() }
        .sheet(isPresented: $showChannelPicker) { channelPicker }
        .sheet(item: $previewTarget) { target in
            TelegramPreviewView(
                chat: target.chat,
                messages: previewMessages(for: target.chat),
                initial: target.message)
        }
        .alert(item: $dialog) { item in
            switch item {
            case .batch:
                return Alert(
                    title: Text(NSLocalizedString("telegram.batch.title", comment: "")),
                    message: Text(String(
                        format: NSLocalizedString("telegram.batch.body", comment: ""),
                        batchMessages.count)),
                    primaryButton: .cancel(Text(NSLocalizedString("telegram.cancel", comment: ""))),
                    secondaryButton: .default(Text(NSLocalizedString("telegram.batch.action", comment: ""))) {
                        guard let chat = selectedChat else { return }
                        Task { await telegram.downloadAll(batchMessages, from: chat) }
                    })
            case .logout:
                return Alert(
                    title: Text(NSLocalizedString("telegram.logout.title", comment: "")),
                    message: Text(NSLocalizedString("telegram.logout.body", comment: "")),
                    primaryButton: .cancel(Text(NSLocalizedString("telegram.cancel", comment: ""))),
                    secondaryButton: .destructive(Text(NSLocalizedString("telegram.logout.action", comment: ""))) {
                        selectedChat = nil
                        previewTarget = nil
                        Task { await telegram.logout() }
                    })
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 14) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .black))
                        Text(NSLocalizedString("miniapps.back", comment: ""))
                    }
                }
                .neoButton(bg: Neo.yellow)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(NSLocalizedString("telegram.title", comment: ""))
                        .font(NeoFont.f(31, .black))
                        .textCase(.uppercase)
                        .foregroundStyle(heroInk)
                        .lineLimit(1)
                    TelegramSignalBars(tint: Neo.yellow)
                        .padding(.bottom, 3)
                    TelegramTag(
                        text: NSLocalizedString("telegram.sticker", comment: ""),
                        tint: Neo.yellow)
                }

                HStack(spacing: 8) {
                    TelegramStatusPill(
                        text: statusText,
                        tint: statusTint,
                        busy: telegram.authState == .unknown || telegram.authState == .loggingIn)
                    Text(heroSubtitle)
                        .font(NeoFont.f(9, .bold))
                        .tracking(1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(heroInk.opacity(0.62))
                        .lineLimit(1)
                    if let selfName = telegram.selfName, !selfName.isEmpty {
                        Text("·")
                            .font(NeoFont.f(9, .bold))
                            .foregroundStyle(heroInk.opacity(0.40))
                        Text(selfName)
                            .font(NeoFont.f(9, .bold))
                            .foregroundStyle(heroInk.opacity(0.62))
                            .lineLimit(1)
                    }
                    if telegram.authState == .ready, !telegram.chats.isEmpty {
                        Text("·")
                            .font(NeoFont.f(9, .bold))
                            .foregroundStyle(heroInk.opacity(0.40))
                        Text(String(
                            format: NSLocalizedString("miniapps.chats.format", comment: ""),
                            telegram.chats.count))
                            .font(NeoFont.f(9, .bold))
                            .foregroundStyle(heroInk.opacity(0.62))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                if telegram.authState == .ready {
                    Button {
                        Task { await telegram.loadChats() }
                    } label: {
                        AppIcon("arrow.triangle.2.circlepath", size: 13)
                    }
                    .buttonStyle(NeoIconButtonStyle(bg: Neo.paper(scheme)))
                    .disabled(telegram.loadingChats)
                    .help(NSLocalizedString("telegram.refresh", comment: ""))

                    Button {
                        dialog = .logout
                    } label: {
                        AppIcon("rectangle.portrait.and.arrow.right", size: 13)
                    }
                    .buttonStyle(NeoIconButtonStyle(bg: Neo.yellow))
                    .help(NSLocalizedString("telegram.logout", comment: ""))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Neo.yellow)
                        ThemedIcon(
                            asset: "IconTelegram",
                            system: "paperplane.fill",
                            size: 22)
                            .foregroundStyle(Neo.inkLight)
                    }
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(-5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Neo.inkLight, lineWidth: 2))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .trailing) {
                Neo.purple
                ThemedIcon(
                    asset: "IconTelegram",
                    system: "paperplane.fill",
                    size: 170)
                    .foregroundStyle(Color.white.opacity(0.10))
                    .rotationEffect(.degrees(-10))
                    .offset(x: -36, y: 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 5, y: 5)
                .opacity(Neo.shape.brutalist ? 1 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: Neo.shape.cardBorder)
                .allowsHitTesting(false))
    }

    private var heroInk: Color {
        Neo.onAccent(Neo.purple, scheme: scheme)
    }

    private var heroSubtitle: String {
        NSLocalizedString("telegram.hero.subtitle", comment: "")
    }

    private var statusText: String {
        switch telegram.authState {
        case .ready: NSLocalizedString("telegram.status.connected", comment: "")
        case .loggingIn: NSLocalizedString("telegram.status.waiting", comment: "")
        case .needs2FA: NSLocalizedString("telegram.status.2fa", comment: "")
        case .loggedOut: NSLocalizedString("telegram.status.offline", comment: "")
        case .failed: NSLocalizedString("telegram.status.error", comment: "")
        case .unknown: NSLocalizedString("telegram.status.checking", comment: "")
        }
    }

    private var statusTint: Color {
        switch telegram.authState {
        case .ready: Neo.green
        case .failed: Neo.red
        case .needs2FA, .loggedOut: Neo.yellow
        case .unknown, .loggingIn: Neo.blue
        }
    }

    // MARK: - Login

    private var loadingCard: some View {
        HStack(spacing: 12) {
            NeoSpinner(size: 18, fill: Neo.blue)
            Text(NSLocalizedString("telegram.status.checking", comment: ""))
                .font(NeoFont.f(.body, .semibold))
                .foregroundStyle(Neo.ink(scheme))
            Spacer()
        }
        .neoCard(accent: Neo.blue, inset: 18)
    }

    private var loginCard: some View {
        HStack(alignment: .center, spacing: 26) {
            qrSticker

            VStack(alignment: .leading, spacing: 11) {
                Text(NSLocalizedString("telegram.login.title", comment: ""))
                    .font(NeoFont.f(25, .black))
                    .foregroundStyle(Neo.ink(scheme))
                    .lineLimit(2)
                Text(NSLocalizedString("telegram.login.body", comment: ""))
                    .font(NeoFont.f(.body))
                    .foregroundStyle(Neo.ink2(scheme))

                if telegram.authState == .needs2FA {
                    Text(NSLocalizedString("telegram.2fa.body", comment: ""))
                        .font(NeoFont.f(.caption))
                        .foregroundStyle(Neo.ink2(scheme))
                    SecureField(
                        NSLocalizedString("telegram.2fa.placeholder", comment: ""),
                        text: $twoStepPassword)
                        .neoTextField()
                        .frame(maxWidth: 320)
                    HStack(spacing: 10) {
                        Button(NSLocalizedString("telegram.2fa.verify", comment: "")) {
                            let password = twoStepPassword
                            twoStepPassword = ""
                            telegram.login(password: password)
                        }
                        .neoButton(bg: Neo.yellow)
                        .disabled(twoStepPassword.isEmpty)
                        Button(NSLocalizedString("telegram.cancel", comment: "")) {
                            twoStepPassword = ""
                            telegram.cancelLogin()
                        }
                        .neoButton(bg: Neo.paper(scheme))
                    }
                } else {
                    if telegram.authState == .loggingIn {
                        HStack(spacing: 8) {
                            NeoSpinner(size: 14, fill: Neo.yellow)
                            Text(NSLocalizedString("telegram.login.waiting", comment: ""))
                                .font(NeoFont.f(.body, .semibold))
                                .foregroundStyle(Neo.ink(scheme))
                        }
                    }

                    HStack(spacing: 10) {
                        if telegram.authState == .loggingIn {
                            Button(NSLocalizedString("telegram.cancel", comment: "")) {
                                telegram.cancelLogin()
                            }
                            .neoButton(bg: Neo.paper(scheme))
                        } else if case .failed = telegram.authState {
                            Button(NSLocalizedString("telegram.retry", comment: "")) {
                                telegram.login()
                            }
                            .neoButton(bg: Neo.yellow)
                        } else {
                            Button(NSLocalizedString("telegram.connect", comment: "")) {
                                telegram.login()
                            }
                            .neoButton(bg: Neo.yellow)
                        }

                        HStack(spacing: 5) {
                            AppIcon("lock", size: 10)
                            Text(NSLocalizedString("telegram.login.hint", comment: ""))
                                .lineLimit(2)
                        }
                        .font(NeoFont.f(.caption2))
                        .foregroundStyle(Neo.ink3(scheme))
                    }
                }

                if let error = telegram.errorMessage, !error.isEmpty {
                    errorCard(error)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: 900, alignment: .leading)
        .neoCard(accent: Neo.purple, inset: 0)
        .padding(.horizontal, 2)
    }

    private var qrSticker: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                if let qrURL = telegram.qrURL, let image = QRCode.image(for: qrURL) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if telegram.authState == .needs2FA {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 62, weight: .black))
                        .foregroundStyle(Neo.purple)
                } else if telegram.authState == .loggingIn {
                    NeoSpinner(size: 30, fill: Neo.purple)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(Neo.ink3(scheme))
                }
            }
            .frame(width: 236, height: 236)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Neo.inkLight, lineWidth: 2.5))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Neo.inkLight)
                    .offset(x: 5, y: 5))
            .rotationEffect(.degrees(-2))

            Text(NSLocalizedString("telegram.login.qr", comment: ""))
                .font(NeoFont.f(.caption2, .semibold))
                .foregroundStyle(Neo.ink2(scheme))
                .multilineTextAlignment(.center)
                .frame(width: 250)
        }
    }

    // MARK: - Workbench

    private var workbench: some View {
        VStack(spacing: 10) {
            if let error = telegram.errorMessage, !error.isEmpty {
                errorCard(error)
            }
            channelTicket
            commandRow
            filterRail
            mediaLibrary
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var channelTicket: some View {
        HStack(spacing: 12) {
            Button {
                openPicker()
            } label: {
                HStack(spacing: 12) {
                    if let chat = selectedChat {
                        TelegramAvatar(chat: chat, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(chat.displayTitle)
                                    .font(NeoFont.f(16, .heavy))
                                    .foregroundStyle(Neo.ink(scheme))
                                    .lineLimit(1)
                                TelegramTag(
                                    text: TelegramStyle.kindTag(chat),
                                    tint: TelegramStyle.chatTint(chat))
                            }
                            Text(chat.subtitle)
                                .font(NeoFont.f(.caption2))
                                .foregroundStyle(Neo.ink2(scheme))
                                .lineLimit(1)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Neo.purple.opacity(0.14))
                            Image(systemName: "rectangle.stack.badge.person.crop")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Neo.purple)
                        }
                        .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(NSLocalizedString("telegram.chooseChannel", comment: ""))
                                .font(NeoFont.f(16, .heavy))
                                .foregroundStyle(Neo.ink(scheme))
                            Text(NSLocalizedString("telegram.pick", comment: ""))
                                .font(NeoFont.f(.caption2))
                                .foregroundStyle(Neo.ink2(scheme))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            if let chat = selectedChat {
                let messages = telegram.messages(for: chat)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(messages.count) \(NSLocalizedString("telegram.files", comment: ""))")
                        .font(NeoFont.f(11, .bold))
                        .foregroundStyle(Neo.ink(scheme))
                        .lineLimit(1)
                    Text(formatBytes(messages.reduce(Int64(0)) { $0 + $1.sizeValue }))
                        .font(NeoFont.f(9, .semibold))
                        .foregroundStyle(Neo.ink3(scheme))
                        .lineLimit(1)
                }
            }

            Rectangle()
                .fill(Neo.ink(scheme).opacity(0.18))
                .frame(width: 1, height: 32)

            Button {
                openPicker()
            } label: {
                HStack(spacing: 6) {
                    AppIcon("rectangle.stack", size: 12)
                    Text(NSLocalizedString("telegram.switch", comment: ""))
                }
            }
            .neoButton(bg: Neo.yellow)
            .controlSize(.small)

            if let chat = selectedChat {
                Button {
                    Task { await telegram.loadMessages(for: chat) }
                } label: {
                    AppIcon("arrow.triangle.2.circlepath", size: 12)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.paper(scheme)))
                .disabled(telegram.loadingMessages)
                .help(NSLocalizedString("telegram.refresh", comment: ""))
            }
        }
        .neoCard(
            accent: selectedChat.map { TelegramStyle.chatTint($0) } ?? Neo.purple,
            inset: 12)
    }

    private var commandRow: some View {
        HStack(spacing: 10) {
            searchField(
                text: $searchText,
                placeholder: NSLocalizedString("telegram.search", comment: ""),
                enabled: selectedChat != nil)
                .frame(maxWidth: 380)

            if telegram.loadingMessages {
                NeoSpinner(size: 14, fill: Neo.purple)
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Text("\(filteredMessages.count)")
                    .font(NeoFont.f(11, .black))
                    .foregroundStyle(Neo.ink(scheme))
                Text(NSLocalizedString("telegram.files", comment: ""))
                    .font(NeoFont.f(10, .semibold))
                    .foregroundStyle(Neo.ink2(scheme))
                if filteredSize > 0 {
                    Text("·")
                        .foregroundStyle(Neo.ink3(scheme))
                    Text(formatBytes(filteredSize))
                        .font(NeoFont.f(10, .bold))
                        .foregroundStyle(Neo.ink3(scheme))
                }
            }
            .lineLimit(1)

            Button {
                dialog = .batch
            } label: {
                HStack(spacing: 6) {
                    AppIcon("arrow.down", size: 11)
                    Text(NSLocalizedString("telegram.downloadAll", comment: ""))
                }
            }
            .neoButton(bg: Neo.purple)
            .controlSize(.small)
            .disabled(batchMessages.isEmpty || telegram.loadingMessages)
            .help(NSLocalizedString("telegram.destination", comment: ""))
        }
    }

    private var filterRail: some View {
        HStack(spacing: 6) {
            ForEach(TelegramMediaFilter.allCases) { item in
                filterChip(item)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                AppIcon("lock", size: 9)
                Text(NSLocalizedString("telegram.safety", comment: ""))
                    .lineLimit(1)
            }
            .font(NeoFont.f(.caption2))
            .foregroundStyle(Neo.ink3(scheme))
        }
    }

    private func filterChip(_ item: TelegramMediaFilter) -> some View {
        let selected = filter == item
        let tint = item == .all ? Neo.yellow : TelegramStyle.tint(for: item)
        let value = count(for: item)
        return Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                AppIcon(filterIcon(item), size: 11)
                Text(item.title)
                    .font(NeoFont.f(.caption, .bold))
                Text("\(value)")
                    .font(NeoFont.f(9, .black))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Neo.inkLight : Neo.ink2(scheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.55) : Neo.card(scheme))
                    .clipShape(Capsule())
            }
            .foregroundStyle(selected ? Neo.onAccent(tint, scheme: scheme) : Neo.ink2(scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? tint : Neo.card(scheme))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    Neo.ink(scheme),
                    lineWidth: Neo.shape.brutalist ? (selected ? 2 : 1.25) : 0.75)
                    .allowsHitTesting(false))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func filterIcon(_ item: TelegramMediaFilter) -> String {
        switch item {
        case .all: "square.grid.2x2"
        case .video: "film"
        case .photo: "photo"
        case .audio: "waveform"
        case .file: "doc"
        }
    }

    @ViewBuilder
    private var mediaLibrary: some View {
        if let chat = selectedChat {
            let shown = filteredMessages
            if shown.isEmpty {
                if telegram.loadingMessages {
                    skeletonGrid
                } else {
                    emptyFilterState
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(shown) { message in
                            mediaCard(message, chat: chat)
                        }
                    }
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            emptyPickState
        }
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                spacing: 12
            ) {
                ForEach(0..<6, id: \.self) { index in
                    TelegramSkeletonCard(tint: [Neo.purple, Neo.blue, Neo.orange, Neo.green][index % 4])
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func mediaCard(_ message: TelegramMessage, chat: TelegramChat) -> some View {
        TelegramMediaCardView(
            message: message,
            tint: message.previewKind.map { TelegramStyle.tint(for: $0) }
                ?? TelegramStyle.tint(for: message.mediaKind),
            cachedURL: telegram.cachedPreviewURL(for: message, in: chat),
            progress: telegram.downloadProgress(for: message, in: chat),
            downloadedURL: telegram.downloadedURL(for: message, in: chat),
            onPreview: {
                previewTarget = PreviewTarget(chat: chat, message: message)
            },
            onDownload: {
                Task { await telegram.download(message, from: chat) }
            },
            onReveal: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
    }

    // MARK: - Empty states

    private var emptyFilterState: some View {
        VStack(spacing: 12) {
            if ThemeRuntime.current == .classic {
                StickerPlate(
                    asset: emptyFilterStickerAsset,
                    fallback: "line.3.horizontal.decrease",
                    size: 84)
                    .padding(.bottom, 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Neo.purple.opacity(0.12))
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Neo.purple)
                }
                .frame(width: 68, height: 68)
            }

            Text(NSLocalizedString("telegram.media.empty", comment: ""))
                .font(NeoFont.f(.body, .semibold))
                .foregroundStyle(Neo.ink2(scheme))
                .multilineTextAlignment(.center)

            if filter != .all || !searchText.isEmpty {
                Button(NSLocalizedString("telegram.filter.all", comment: "")) {
                    filter = .all
                    searchText = ""
                }
                .neoButton(bg: Neo.paper(scheme))
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    private var emptyFilterStickerAsset: String {
        selectedChat?.kind == "self" ? "StickerBookmark" : "StickerSearch"
    }

    private var emptyPickState: some View {
        ScrollView {
            VStack(spacing: 14) {
                if ThemeRuntime.current == .classic {
                    StickerPlate(
                        asset: "StickerPaperPlane",
                        fallback: "paperplane.fill",
                        size: 104)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Neo.purple)
                        ThemedIcon(asset: "IconTelegram", system: "paperplane.fill", size: 46)
                            .foregroundStyle(Neo.onAccent(Neo.purple, scheme: scheme))
                    }
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(-5))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Neo.ink(scheme))
                            .offset(x: 5, y: 5)
                            .opacity(Neo.shape.brutalist ? 1 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Neo.ink(scheme), lineWidth: Neo.shape.brutalist ? 2.5 : 1))
                }

                Text(NSLocalizedString("telegram.media.emptyChannel", comment: ""))
                    .font(NeoFont.f(.title3, .heavy))
                    .foregroundStyle(Neo.ink(scheme))
                    .multilineTextAlignment(.center)

                Button {
                    openPicker()
                } label: {
                    HStack(spacing: 6) {
                        AppIcon("rectangle.stack", size: 12)
                        Text(NSLocalizedString("telegram.pick", comment: ""))
                    }
                }
                .neoButton(bg: Neo.yellow)

                if !telegram.chats.isEmpty {
                    Text(NSLocalizedString("telegram.quickPick", comment: ""))
                        .font(NeoFont.f(10, .black))
                        .tracking(1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(Neo.ink3(scheme))
                        .padding(.top, 4)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(Array(telegram.chats.prefix(8))) { chat in
                            quickPickRow(chat)
                        }
                    }
                    .frame(maxWidth: 840)
                } else if telegram.loadingChats {
                    NeoSpinner(size: 18, fill: Neo.purple)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 18)
            .neoCard(accent: Neo.purple, inset: 0)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func quickPickRow(_ chat: TelegramChat) -> some View {
        Button {
            open(chat)
        } label: {
            HStack(spacing: 9) {
                TelegramAvatar(chat: chat, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.displayTitle)
                        .font(NeoFont.f(.caption, .bold))
                        .foregroundStyle(Neo.ink(scheme))
                        .lineLimit(1)
                    Text(chat.subtitle)
                        .font(NeoFont.f(9))
                        .foregroundStyle(Neo.ink2(scheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                AppIcon("chevron.right", size: 9)
                    .foregroundStyle(Neo.ink3(scheme))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Neo.card(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Neo.ink(scheme).opacity(0.15), lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(telegram.loadingMessages)
    }

    // MARK: - Channel picker

    private var channelPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    TelegramTag(
                        text: NSLocalizedString("telegram.picker.title", comment: ""),
                        tint: Neo.yellow)
                    Text(NSLocalizedString("telegram.pick", comment: ""))
                        .font(NeoFont.f(24, .black))
                        .foregroundStyle(Neo.onAccent(Neo.purple, scheme: scheme))
                }
                Spacer()
                if telegram.loadingChats {
                    NeoSpinner(size: 15, fill: Neo.yellow)
                }
                Text(String(
                    format: NSLocalizedString("miniapps.chats.format", comment: ""),
                    telegram.chats.count))
                    .font(NeoFont.f(10, .bold))
                    .foregroundStyle(Neo.onAccent(Neo.purple, scheme: scheme).opacity(0.7))
                Button {
                    showChannelPicker = false
                } label: {
                    AppIcon("xmark", size: 12)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.paper(scheme)))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                ZStack(alignment: .trailing) {
                    Neo.purple
                    ThemedIcon(asset: "IconTelegram", system: "paperplane.fill", size: 108)
                        .foregroundStyle(Color.white.opacity(0.10))
                        .rotationEffect(.degrees(-10))
                        .offset(x: -20, y: 12)
                }
            }

            VStack(spacing: 10) {
                searchField(
                    text: $channelSearch,
                    placeholder: NSLocalizedString("telegram.picker.search", comment: ""),
                    enabled: true)

                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(pickerChats) { chat in
                            pickerRow(chat)
                        }
                        if pickerChats.isEmpty && !telegram.loadingChats {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(Neo.ink3(scheme))
                                Text(NSLocalizedString("telegram.picker.empty", comment: ""))
                                    .font(NeoFont.f(.caption))
                                    .foregroundStyle(Neo.ink2(scheme))
                            }
                            .padding(.vertical, 34)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 6) {
                    AppIcon("lock", size: 9)
                    Text(NSLocalizedString("telegram.picker.note", comment: ""))
                        .font(NeoFont.f(.caption2))
                        .foregroundStyle(Neo.ink3(scheme))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .frame(width: 580, height: 640)
        .background(Neo.paper(scheme))
    }

    private func pickerRow(_ chat: TelegramChat) -> some View {
        TelegramPickerRow(
            chat: chat,
            selected: selectedChat?.id == chat.id,
            disabled: telegram.loadingMessages) {
                showChannelPicker = false
                open(chat)
            }
    }

    private var pickerChats: [TelegramChat] {
        let query = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return telegram.chats }
        return telegram.chats.filter {
            $0.displayTitle.lowercased().contains(query)
                || ($0.username?.lowercased().contains(query) ?? false)
        }
    }

    // MARK: - Search field

    private func searchField(
        text: Binding<String>,
        placeholder: String,
        enabled: Bool
    ) -> some View {
        HStack(spacing: 8) {
            AppIcon("magnifyingglass", size: 12)
                .foregroundStyle(Neo.ink2(scheme))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(NeoFont.f(.subheadline))
                .foregroundStyle(Neo.ink(scheme))
                .disabled(!enabled)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    AppIcon("xmark", size: 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Neo.ink3(scheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Neo.paper(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Neo.shape.fieldRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Neo.shape.fieldRadius, style: .continuous)
                .stroke(
                    Neo.shape.brutalist ? Neo.ink(scheme) : Neo.ink(scheme).opacity(0.12),
                    lineWidth: Neo.shape.fieldBorder)
                .allowsHitTesting(false))
        .opacity(enabled ? 1 : 0.55)
    }

    // MARK: - Shared

    private func open(_ chat: TelegramChat) {
        selectedChat = chat
        searchText = ""
        filter = .all
        Task { await telegram.loadMessages(for: chat) }
    }

    private func openPicker() {
        channelSearch = ""
        showChannelPicker = true
    }

    private var filteredMessages: [TelegramMessage] {
        guard let chat = selectedChat else { return [] }
        return previewMessages(for: chat)
    }

    /// Batch actions must not promise files the helper cannot fetch. The
    /// service also skips these, but the confirmation count and disabled
    /// state should reflect what will actually be downloaded.
    private var batchMessages: [TelegramMessage] {
        filteredMessages.filter(\.canDownload)
    }

    private func previewMessages(for chat: TelegramChat) -> [TelegramMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return telegram.messages(for: chat).filter { message in
            guard filter.matches(message) else { return false }
            guard !query.isEmpty else { return true }
            return message.displayName.lowercased().contains(query)
                || (message.text?.lowercased().contains(query) ?? false)
        }
    }

    private var filteredSize: Int64 {
        filteredMessages.reduce(Int64(0)) { $0 + $1.sizeValue }
    }

    private func count(for filter: TelegramMediaFilter) -> Int {
        guard let chat = selectedChat else { return 0 }
        return telegram.messages(for: chat).filter { filter.matches($0) }.count
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Neo.red)
            Text(message)
                .font(NeoFont.f(.caption))
                .foregroundStyle(Neo.ink(scheme))
            Spacer(minLength: 4)
            Button {
                telegram.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Neo.ink2(scheme))
        }
        .padding(9)
        .background(Neo.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Neo.red.opacity(0.55), lineWidth: 1))
    }
}

// MARK: - Preview routing

private struct PreviewTarget: Identifiable {
    let chat: TelegramChat
    let message: TelegramMessage
    var id: Int { message.id }
}

// MARK: - Media card

private struct TelegramMediaCardView: View {
    let message: TelegramMessage
    let tint: Color
    let cachedURL: URL?
    let progress: Double?
    let downloadedURL: URL?
    let onPreview: () -> Void
    let onDownload: () -> Void
    let onReveal: (URL) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            poster
            VStack(alignment: .leading, spacing: 7) {
                Text(message.displayName)
                    .font(NeoFont.f(.subheadline, .bold))
                    .foregroundStyle(Neo.ink(scheme))
                    .lineLimit(2)

                HStack(spacing: 5) {
                    if message.sizeValue > 0 {
                        Text(formatBytes(message.sizeValue))
                            .font(NeoFont.f(.caption2))
                            .foregroundStyle(Neo.ink2(scheme))
                    }
                    if let dimensions = message.dimensionsText {
                        Text("·").foregroundStyle(Neo.ink3(scheme))
                        Text(dimensions)
                            .font(NeoFont.f(.caption2))
                            .foregroundStyle(Neo.ink2(scheme))
                    }
                    Text("·").foregroundStyle(Neo.ink3(scheme))
                    Text(TelegramStyle.dateText(message))
                        .font(NeoFont.f(.caption2))
                        .foregroundStyle(Neo.ink3(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)

                if let text = message.text, !text.isEmpty {
                    Text(text)
                        .font(NeoFont.f(.caption2))
                        .foregroundStyle(Neo.ink2(scheme))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if message.isPreviewable && message.canDownload {
                        Button {
                            onPreview()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: previewIcon)
                                    .font(.system(size: 10, weight: .black))
                                Text(previewLabel)
                            }
                        }
                        .neoButton(bg: tint)
                        .controlSize(.small)
                    } else {
                        TelegramTag(
                            text: TelegramStyle.mediaLabel(for: message),
                            tint: Neo.ink3(scheme),
                            filled: false)
                    }

                    Spacer(minLength: 0)

                    downloadControl
                }
                .padding(.top, 1)
            }
            .padding(11)
        }
        .background(Neo.card(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 4, y: 4)
                .opacity(Neo.shape.brutalist ? 1 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: Neo.shape.cardBorder)
                .allowsHitTesting(false))
        .scaleEffect(hovering ? 1.006 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
    }

    // MARK: Poster

    private var poster: some View {
        Button {
            if message.isPreviewable && message.canDownload { onPreview() }
        } label: {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [tint.opacity(0.34), tint.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)

                if let cachedURL, message.previewKind != .audio {
                    TelegramPosterThumb(url: cachedURL, kind: message.previewKind)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    LinearGradient(
                        colors: [.black.opacity(0.30), .clear, .black.opacity(0.46)],
                        startPoint: .top,
                        endPoint: .bottom)
                } else {
                    Image(systemName: message.icon)
                        .font(.system(size: 82, weight: .black))
                        .foregroundStyle(tint.opacity(0.20))
                        .rotationEffect(.degrees(-8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(x: 18, y: 10)
                }

                HStack(alignment: .top) {
                    TelegramTag(
                        text: TelegramStyle.mediaLabel(for: message),
                        tint: tint)
                    Spacer(minLength: 6)
                    if let duration = message.durationText {
                        posterChip(duration, icon: "clock")
                    } else if let dimensions = message.dimensionsText {
                        posterChip(dimensions, icon: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .padding(9)

                if message.isPreviewable && message.canDownload {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: previewIcon)
                                .font(.system(size: 11, weight: .black))
                            Text(previewLabel)
                                .font(NeoFont.f(9, .black))
                                .tracking(0.8)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        .scaleEffect(hovering ? 1.04 : 1)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(9)
                }

                if hovering && message.isPreviewable && message.canDownload {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.58))
                            .frame(width: 46, height: 46)
                        Circle()
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                            .frame(width: 46, height: 46)
                        Image(systemName: previewIcon)
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 112)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!message.isPreviewable || !message.canDownload)
    }

    private func posterChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(NeoFont.f(9, .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.52)))
    }

    // MARK: Footer actions

    @ViewBuilder
    private var downloadControl: some View {
        if let progress {
            if progress < 0.001 {
                // The helper needs a moment to connect (and, on the first
                // transfer, to reach the file DC). An indeterminate spinner
                // reads better than a frozen 0% ring during that handshake.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(tint)
                    .frame(width: 30, height: 30)
                    .padding(2)
            } else {
                ZStack {
                    Circle()
                        .stroke(Neo.ink(scheme).opacity(0.14), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))")
                        .font(NeoFont.f(8, .black))
                        .monospacedDigit()
                        .foregroundStyle(Neo.ink2(scheme))
                }
                .frame(width: 30, height: 30)
                .padding(2)
            }
        } else if let downloadedURL {
            Button {
                onReveal(downloadedURL)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Neo.onAccent(Neo.green, scheme: scheme))
                    .frame(width: 30, height: 30)
                    .background(Neo.green)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("task.details.openFinder", comment: ""))
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(tint.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!message.canDownload)
            .help(NSLocalizedString("telegram.download", comment: ""))
        }
    }

    private var previewIcon: String {
        switch message.previewKind {
        case .photo: "eye.fill"
        case .video: "play.fill"
        case .audio: "waveform"
        case nil: "arrow.down"
        }
    }

    private var previewLabel: String {
        switch message.previewKind {
        case .photo: NSLocalizedString("telegram.view", comment: "")
        case .video: NSLocalizedString("telegram.play", comment: "")
        case .audio: NSLocalizedString("telegram.listen", comment: "")
        case nil: NSLocalizedString("telegram.download", comment: "")
        }
    }
}

// MARK: - Skeleton

private struct TelegramSkeletonCard: View {
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                tint.opacity(0.16)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.30))
                    .frame(width: 58, height: 18)
                    .padding(9)
            }
            .frame(height: 112)

            VStack(alignment: .leading, spacing: 8) {
                skeletonBar(width: 0.72, height: 12)
                skeletonBar(width: 0.48, height: 9)
                skeletonBar(width: 0.86, height: 8)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.24))
                        .frame(width: 62, height: 24)
                    Spacer()
                    Circle()
                        .fill(Neo.ink3(scheme).opacity(0.18))
                        .frame(width: 30, height: 30)
                }
                .padding(.top, 3)
            }
            .padding(11)
        }
        .background(Neo.card(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Neo.shape.cardRadius, style: .continuous)
                .stroke(Neo.ink(scheme).opacity(0.20), lineWidth: Neo.shape.cardBorder))
        .opacity(0.85)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Neo.ink3(scheme).opacity(0.14))
                .frame(width: geometry.size.width * width, height: height)
        }
        .frame(height: height)
    }
}

// MARK: - Picker row

private struct TelegramPickerRow: View {
    let chat: TelegramChat
    let selected: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TelegramAvatar(chat: chat, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(chat.displayTitle)
                            .font(NeoFont.f(.subheadline, .bold))
                            .lineLimit(1)
                        if chat.kind == "self" {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(selected ? Neo.yellow : Neo.ink3(scheme))
                        }
                    }
                    Text(chat.subtitle)
                        .font(NeoFont.f(.caption2))
                        .foregroundStyle(foreground.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                TelegramTag(
                    text: TelegramStyle.kindTag(chat),
                    tint: selected ? Neo.yellow : TelegramStyle.chatTint(chat))

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(foreground)
                        .padding(.leading, 2)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowBackground)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? Neo.ink(scheme) : Neo.ink(scheme).opacity(hovering ? 0.2 : 0.08),
                        lineWidth: selected ? (Neo.shape.brutalist ? 2 : 1) : 0.75)
                    .allowsHitTesting(false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        selected ? Neo.onAccent(Neo.purple, scheme: scheme) : Neo.ink(scheme)
    }

    private var rowBackground: Color {
        if selected { return Neo.purple }
        return hovering ? Neo.card(scheme).opacity(0.9) : .clear
    }
}

// MARK: - Dialogs & QR

private enum TelegramDialog: String, Identifiable {
    case batch
    case logout
    var id: String { rawValue }
}

/// Renders a `tg://login?token=...` payload as a crisp QR image.
enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
