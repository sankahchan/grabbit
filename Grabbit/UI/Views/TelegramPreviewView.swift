import AVFoundation
import AVKit
import AppKit
import Combine
import SwiftUI

/// In-app media viewer for Telegram. Files are fetched into the caches
/// directory on demand, then rendered with NSImage / AVKit — watching a clip
/// never writes to Downloads. The header keeps the existing download flow one
/// click away.
struct TelegramPreviewView: View {
    let chat: TelegramChat
    let playlist: [TelegramMessage]

    @Environment(TelegramService.self) private var telegram
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var index: Int
    @State private var phase: Phase = .loading
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var assetDuration: Double = 0
    @State private var loadTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    init(chat: TelegramChat, messages: [TelegramMessage], initial: TelegramMessage) {
        let previewable = messages.filter { $0.isPreviewable && $0.canDownload }
        let list = previewable.contains(where: { $0.id == initial.id })
            ? previewable
            : [initial]
        self.chat = chat
        self.playlist = list
        _index = State(initialValue: list.firstIndex(where: { $0.id == initial.id }) ?? 0)
    }

    private var message: TelegramMessage {
        playlist[min(max(index, 0), playlist.count - 1)]
    }

    private var tint: Color { TelegramStyle.tint(for: message.previewKind) }

    var body: some View {
        VStack(spacing: 12) {
            header
            stage
            footer
        }
        .padding(14)
        .frame(width: 1000, height: 680)
        .background(Neo.paper(scheme))
        .onAppear(perform: loadCurrent)
        .onChange(of: index) { _, _ in loadCurrent() }
        .onChange(of: telegram.downloadedURL(for: message, in: chat)) { _, url in
            guard url != nil, phase != .ready else { return }
            loadCurrent()
        }
        .onDisappear(perform: teardown)
        .onExitCommand { close() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint)
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Neo.onAccent(tint, scheme: scheme))
            }
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Neo.ink(scheme))
                    .offset(x: 3, y: 3)
                    .opacity(Neo.shape.brutalist ? 1 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: Neo.shape.brutalist ? 2 : 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TelegramTag(
                        text: TelegramStyle.mediaLabel(for: message),
                        tint: tint)
                    Text(positionText)
                        .font(NeoFont.f(9, .bold))
                        .foregroundStyle(Neo.ink3(scheme))
                }
                Text(message.displayName)
                    .font(NeoFont.f(17, .heavy))
                    .foregroundStyle(Neo.ink(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine)
                    .font(NeoFont.f(.caption2))
                    .foregroundStyle(Neo.ink2(scheme))
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            downloadControl

            if let downloadedURL = telegram.downloadedURL(for: message, in: chat) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
                } label: {
                    AppIcon("folder", size: 13)
                }
                .buttonStyle(NeoIconButtonStyle(bg: Neo.green))
                .help(NSLocalizedString("task.details.openFinder", comment: ""))
            }

            Button {
                close()
            } label: {
                AppIcon("xmark", size: 12)
            }
            .buttonStyle(NeoIconButtonStyle(bg: Neo.paper(scheme)))
            .keyboardShortcut(.cancelAction)
            .help(NSLocalizedString("common.close", comment: ""))
        }
        .neoCard(accent: tint, inset: 10)
    }

    @ViewBuilder
    private var downloadControl: some View {
        if let progress = telegram.downloadProgress(for: message, in: chat) {
            HStack(spacing: 7) {
                ProgressView(value: progress)
                    .tint(tint)
                    .frame(width: 78)
                Text("\(Int(progress * 100))%")
                    .font(NeoFont.f(9, .bold))
                    .foregroundStyle(Neo.ink2(scheme))
                    .monospacedDigit()
            }
        } else if telegram.downloadedURL(for: message, in: chat) != nil {
            Label(
                NSLocalizedString("telegram.downloaded", comment: ""),
                systemImage: "checkmark.circle.fill")
                .font(NeoFont.f(.caption2, .bold))
                .foregroundStyle(Neo.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Neo.green.opacity(0.12))
                .clipShape(Capsule())
        } else {
            Button {
                Task { await telegram.download(message, from: chat) }
            } label: {
                HStack(spacing: 6) {
                    AppIcon("arrow.down", size: 11)
                    Text(NSLocalizedString("telegram.download", comment: ""))
                }
            }
            .neoButton(bg: tint)
            .controlSize(.small)
            .disabled(!message.canDownload)
        }
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            TelegramStageBackdrop(tint: tint)

            switch phase {
            case .loading:
                loadingStage
            case .failed:
                failedStage
            case .ready:
                readyStage
            }

            navigationOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 4, y: 4)
                .opacity(Neo.shape.brutalist ? 1 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: Neo.shape.brutalist ? 2 : 1)
                .allowsHitTesting(false))
    }

    @ViewBuilder
    private var readyStage: some View {
        if let image {
            TelegramPhotoStage(image: image, tint: tint)
        } else if let player, message.previewKind == .audio {
            TelegramAudioStage(
                player: player,
                message: message,
                duration: assetDuration,
                tint: tint)
        } else if let player {
            TelegramVideoPlayer(player: player)
                .background(Color.black)
                .onAppear { player.play() }
        } else {
            failedStage
        }
    }

    private var loadingStage: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 74, height: 74)
                NeoSpinner(size: 26, fill: tint)
            }
            Text(NSLocalizedString("telegram.preview.preparing", comment: ""))
                .font(NeoFont.f(.subheadline, .bold))
                .foregroundStyle(.white.opacity(0.9))

            if let progress = telegram.previewProgress(for: message, in: chat) {
                VStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule()
                                .fill(tint)
                                .frame(width: max(6, geo.size.width * progress))
                        }
                    }
                    .frame(width: 260, height: 8)
                    Text("\(Int(progress * 100))% · \(formatBytes(message.sizeValue))")
                        .font(NeoFont.f(10, .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text(formatBytes(message.sizeValue))
                    .font(NeoFont.f(10, .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Button(NSLocalizedString("telegram.cancel", comment: "")) {
                close()
            }
            .neoButton(bg: Neo.paper(scheme))
            .controlSize(.small)
        }
    }

    private var failedStage: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 92, height: 92)
                Image(systemName: "eye.slash")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(tint)
            }
            Text(NSLocalizedString("telegram.preview.failed", comment: ""))
                .font(NeoFont.f(.headline, .bold))
                .foregroundStyle(.white)
            Text(message.displayName)
                .font(NeoFont.f(.caption))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                if let progress = telegram.downloadProgress(for: message, in: chat) {
                    HStack(spacing: 7) {
                        ProgressView(value: progress)
                            .tint(tint)
                            .frame(width: 78)
                        Text("\(Int(progress * 100))%")
                            .font(NeoFont.f(9, .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                } else if telegram.downloadedURL(for: message, in: chat) != nil {
                    Button {
                        loadCurrent()
                    } label: {
                        HStack(spacing: 6) {
                            AppIcon("play.fill", size: 11)
                            Text(NSLocalizedString("telegram.preview.openDownloaded", comment: ""))
                        }
                    }
                    .neoButton(bg: Neo.green)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await telegram.download(message, from: chat) }
                    } label: {
                        HStack(spacing: 6) {
                            AppIcon("arrow.down", size: 11)
                            Text(NSLocalizedString("telegram.download", comment: ""))
                        }
                    }
                    .neoButton(bg: tint)
                    .controlSize(.small)
                    .disabled(!message.canDownload)
                }

                Button(NSLocalizedString("common.close", comment: "")) {
                    close()
                }
                .neoButton(bg: Neo.paper(scheme))
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var navigationOverlay: some View {
        if playlist.count > 1 {
            HStack {
                navigationButton(step: -1)
                Spacer()
                navigationButton(step: 1)
            }
            .padding(.horizontal, 12)
        }
    }

    private func navigationButton(step: Int) -> some View {
        let disabled = step < 0 ? index == 0 : index >= playlist.count - 1
        return Button {
            move(by: step)
        } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.black.opacity(0.56)))
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.25 : 1)
        .keyboardShortcut(step < 0 ? .leftArrow : .rightArrow, modifiers: [])
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { move(by: -1) } label: {
                    AppIcon("chevron.left", size: 10)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1)
                .help(NSLocalizedString("telegram.preview.previous", comment: ""))

                Text(positionText)
                    .font(NeoFont.f(.caption2, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Neo.ink2(scheme))

                Button { move(by: 1) } label: {
                    AppIcon("chevron.right", size: 10)
                }
                .buttonStyle(.plain)
                .disabled(index >= playlist.count - 1)
                .opacity(index >= playlist.count - 1 ? 0.3 : 1)
                .help(NSLocalizedString("telegram.preview.next", comment: ""))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Neo.card(scheme))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Neo.ink(scheme).opacity(0.16), lineWidth: 1))

            Spacer(minLength: 8)

            Text(NSLocalizedString("telegram.preview.hint", comment: ""))
                .font(NeoFont.f(.caption2))
                .foregroundStyle(Neo.ink3(scheme))
                .lineLimit(1)

            Text("·")
                .foregroundStyle(Neo.ink3(scheme))

            Text(NSLocalizedString("telegram.safety", comment: ""))
                .font(NeoFont.f(.caption2))
                .foregroundStyle(Neo.ink3(scheme))
                .lineLimit(1)
        }
    }

    // MARK: - Data

    private var iconName: String {
        switch message.previewKind {
        case .photo: "photo"
        case .video: "film"
        case .audio: "waveform"
        case nil: "doc"
        }
    }

    private var positionText: String {
        "\(index + 1) / \(playlist.count)"
    }

    private var metaLine: String {
        var parts: [String] = []
        if message.sizeValue > 0 { parts.append(formatBytes(message.sizeValue)) }
        if let dimensions = message.dimensionsText { parts.append(dimensions) }
        if let duration = message.durationText { parts.append(duration) }
        parts.append(TelegramStyle.dateText(message))
        return parts.joined(separator: " · ")
    }

    private func move(by step: Int) {
        let next = min(max(index + step, 0), playlist.count - 1)
        guard next != index else { return }
        index = next
    }

    private func close() {
        teardown()
        dismiss()
    }

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        telegram.cancelPreview()
        player?.pause()
        player = nil
    }

    private func loadCurrent() {
        teardown()
        phase = .loading
        image = nil
        player = nil
        assetDuration = 0

        let target = message
        loadTask = Task { @MainActor in
            // A file the user already downloaded should be previewed in
            // place rather than fetched into the preview cache again.
            if let downloaded = telegram.downloadedURL(for: target, in: chat),
               !downloaded.pathExtension.isEmpty {
                await show(target, at: downloaded)
                guard !Task.isCancelled, message.id == target.id else { return }
                if phase == .ready { return }
            }

            if let cached = telegram.cachedPreviewURL(for: target, in: chat) {
                guard !Task.isCancelled, message.id == target.id else { return }
                phase = .loading
                await show(target, at: cached)
                return
            }

            phase = .loading
            guard let url = await telegram.preparePreview(target, from: chat) else {
                guard !Task.isCancelled else { return }
                phase = .failed
                return
            }
            guard !Task.isCancelled, message.id == target.id else { return }
            await show(target, at: url)
        }
    }

    private func show(_ target: TelegramMessage, at url: URL) async {
        guard !Task.isCancelled, message.id == target.id else { return }
        switch target.previewKind {
        case .photo:
            guard let loaded = NSImage(contentsOf: url) else {
                guard !Task.isCancelled, message.id == target.id else { return }
                phase = .failed
                return
            }
            guard !Task.isCancelled, message.id == target.id else { return }
            image = loaded
            phase = .ready

        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled, message.id == target.id else { return }
            guard playable else {
                phase = .failed
                return
            }
            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled, message.id == target.id else { return }
            assetDuration = duration
            player = newPlayer
            phase = .ready
            newPlayer.play()

        case nil:
            phase = .failed
        }
    }
}

// MARK: - Stage backdrop

/// Dark projection booth behind every kind of media: a faint grid, a tinted
/// glow and nothing else competing with the content.
struct TelegramStageBackdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            TelegramStyle.stage

            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 36
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 36
                }
                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }

            RadialGradient(
                colors: [tint.opacity(0.22), .clear],
                center: .center,
                startRadius: 8,
                endRadius: 440)
        }
    }
}

// MARK: - Photo

/// Fits the photo to the stage; double-click or trackpad-pinch zooms, and a
/// zoomed image can be scrolled in both directions.
private struct TelegramPhotoStage: View {
    let image: NSImage
    let tint: Color

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            // Compute the aspect-fitted size ourselves. A plain `.frame(width:)`
            // around `.scaledToFit()` can stretch the bitmap when the stage has
            // a different aspect ratio.
            let availableWidth = max(geometry.size.width - 28, 1)
            let availableHeight = max(geometry.size.height - 28, 1)
            let aspect = image.size.width / max(image.size.height, 1)
            let baseWidth = min(availableWidth, availableHeight * aspect)
            let baseHeight = baseWidth / max(aspect, 0.0001)

            ScrollView([.horizontal, .vertical], showsIndicators: zoom > 1) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: baseWidth * zoom, height: baseHeight * zoom)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .center)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = zoom > 1 ? 1 : 2
                    baseZoom = zoom
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = min(max(baseZoom * value.magnification, 1), 4)
                    }
                    .onEnded { _ in
                        baseZoom = zoom
                    })
        }
    }
}

// MARK: - Video

/// AppKit's `AVPlayerView` rather than SwiftUI's `VideoPlayer`: the SwiftUI
/// overlay crashed while resolving its generic metadata on macOS 27, and the
/// AppKit control has the native transport, scrubber and full-screen button
/// we want anyway.
private struct TelegramVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = false
        view.showsSharingServiceButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

// MARK: - Audio

/// Audio gets its own stage instead of a black VideoPlayer rectangle: a
/// waveform plate, scrubber and one large transport button.
private struct TelegramAudioStage: View {
    let player: AVPlayer
    let message: TelegramMessage
    let duration: Double
    let tint: Color

    @Environment(\.colorScheme) private var scheme
    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var scrubbing = false

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var safeDuration: Double {
        duration.isFinite && duration > 0 ? duration : 1
    }

    private var fraction: Double {
        min(max(currentTime / safeDuration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 176, height: 176)
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 176, height: 176)
                Image(systemName: "waveform")
                    .font(.system(size: 62, weight: .black))
                    .foregroundStyle(tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text(message.displayName)
                    .font(NeoFont.f(19, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(audioMeta)
                    .font(NeoFont.f(.caption2))
                    .foregroundStyle(.white.opacity(0.55))
            }

            VStack(spacing: 6) {
                scrubber
                HStack {
                    Text(timeText(currentTime))
                    Spacer()
                    Text(timeText(safeDuration))
                }
                .font(NeoFont.f(10, .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: 440)

            Button {
                togglePlayback()
            } label: {
                ZStack {
                    Circle()
                        .fill(tint)
                        .frame(width: 60, height: 60)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Neo.onAccent(tint, scheme: scheme))
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .onReceive(ticker) { _ in
            guard !scrubbing else { return }
            let seconds = player.currentTime().seconds
            if seconds.isFinite { currentTime = seconds }
            switch player.timeControlStatus {
            case .playing:
                isPlaying = true
            case .paused:
                isPlaying = false
            case .waitingToPlayAtSpecifiedRate:
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem)) { _ in
            isPlaying = false
            player.seek(to: .zero)
            currentTime = 0
        }
    }

    private var scrubber: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 8)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, width * fraction), height: 8)
                Circle()
                    .fill(tint)
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 2))
                    .frame(width: 15, height: 15)
                    .offset(x: max(0, min(width - 15, width * fraction - 7.5)))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        let target = min(max(value.location.x / max(width, 1), 0), 1)
                        currentTime = target * safeDuration
                    }
                    .onEnded { value in
                        let target = min(max(value.location.x / max(width, 1), 0), 1)
                        player.seek(
                            to: CMTime(seconds: target * safeDuration, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero)
                        scrubbing = false
                    })
        }
        .frame(height: 16)
    }

    private var audioMeta: String {
        var parts: [String] = [formatBytes(message.sizeValue)]
        if let durationText = message.durationText { parts.append(durationText) }
        parts.append(TelegramStyle.dateText(message))
        return parts.joined(separator: " · ")
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
