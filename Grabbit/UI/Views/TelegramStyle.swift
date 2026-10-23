import AVFoundation
import AppKit
import SwiftUI

/// Shared visual language for the Telegram mini app. Media type decides the
/// tint, so the grid, filter rail and viewer all read as one system.
enum TelegramStyle {
    static let stage = Color(hex: 0x0B0B0F)
    static let stageLine = Color.white.opacity(0.06)

    static func tint(for kind: String?) -> Color {
        switch kind {
        case "video": Neo.blue
        case "photo": Neo.orange
        case "audio": Neo.green
        case "gif": Neo.red
        case "sticker": Neo.pink
        default: Neo.purple
        }
    }

    static func tint(for preview: TelegramPreviewKind?) -> Color {
        switch preview {
        case .photo: Neo.orange
        case .video: Neo.blue
        case .audio: Neo.green
        case nil: Neo.purple
        }
    }

    static func tint(for filter: TelegramMediaFilter) -> Color {
        switch filter {
        case .all: Neo.purple
        case .video: Neo.blue
        case .photo: Neo.orange
        case .audio: Neo.green
        case .file: Color(hex: 0x70707C)
        }
    }

    static func chatTint(_ chat: TelegramChat) -> Color {
        if chat.kind == "self" { return Neo.yellow }
        let palette: [Color] = [Neo.purple, Neo.blue, Neo.green, Neo.orange, Neo.pink, Neo.red]
        var hash = 5381
        for scalar in chat.title.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ Int(scalar.value)
        }
        // Use the unsigned bit pattern rather than abs(): abs(Int.min) traps,
        // and a Telegram title should never be able to crash the browser.
        let index = Int(UInt(bitPattern: hash) % UInt(palette.count))
        return palette[index]
    }

    static func initial(_ chat: TelegramChat) -> String {
        let trimmed = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "#"
    }

    static func kindTag(_ chat: TelegramChat) -> String {
        switch chat.kind {
        case "self": NSLocalizedString("telegram.kind.private", comment: "")
        case "user": NSLocalizedString("telegram.kind.direct", comment: "")
        case "group": NSLocalizedString("telegram.kind.group", comment: "")
        case "channel": NSLocalizedString("telegram.kind.channel", comment: "")
        default: chat.kind.uppercased()
        }
    }

    static func mediaLabel(for message: TelegramMessage) -> String {
        if let kind = message.previewKind {
            return kind.label
        }
        return switch message.mediaKind {
        case "document": NSLocalizedString("telegram.media.file", comment: "")
        case "sticker": NSLocalizedString("telegram.media.sticker", comment: "")
        default:
            message.mediaKind.map { $0.uppercased() }
                ?? NSLocalizedString("telegram.media.file", comment: "")
        }
    }

    static func dateText(_ message: TelegramMessage) -> String {
        dateFormatter.string(from: message.dateValue)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Micro parts

/// Tiny uppercase capsule used as a taxonomy tag on posters and tickets.
struct TelegramTag: View {
    var text: String
    var tint: Color
    var filled: Bool = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(NeoFont.f(9, .black))
            .tracking(0.7)
            .lineLimit(1)
            .foregroundStyle(filled ? Neo.onAccent(tint, scheme: scheme) : Neo.ink(scheme))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(filled ? tint : Neo.paper(scheme))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Neo.ink(scheme), lineWidth: Neo.shape.brutalist ? 1.5 : 0.75)
                    .allowsHitTesting(false))
    }
}

/// Square avatar sticker with a hard offset block. Initial for people and
/// channels, bookmark for Saved Messages.
struct TelegramAvatar: View {
    var chat: TelegramChat
    var size: CGFloat = 44
    @Environment(\.colorScheme) private var scheme

    private var tint: Color { TelegramStyle.chatTint(chat) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint)
            if chat.kind == "self" {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: size * 0.40, weight: .black))
                    .foregroundStyle(Neo.onAccent(tint, scheme: scheme))
            } else {
                Text(TelegramStyle.initial(chat))
                    .font(NeoFont.f(size * 0.42, .black))
                    .foregroundStyle(Neo.onAccent(tint, scheme: scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Neo.ink(scheme))
                .offset(x: 3, y: 3)
                .opacity(Neo.shape.brutalist ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: Neo.shape.brutalist ? 2 : 1)
                .allowsHitTesting(false))
    }
}

/// Three little signal bars — the "connected" logo next to the status dot.
struct TelegramSignalBars: View {
    var tint: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
    }
}

/// Status dot + label on the purple hero. A soft pulse makes the workbench
/// feel live without animating layout.
struct TelegramStatusPill: View {
    var text: String
    var tint: Color
    var busy: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(tint).frame(width: 7, height: 7)
                if busy {
                    Circle()
                        .stroke(tint.opacity(0.65), lineWidth: 1)
                        .frame(width: 13, height: 13)
                }
            }
            Text(text)
                .font(NeoFont.f(10, .bold))
                .textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(Neo.onAccent(Neo.purple, scheme: scheme).opacity(0.92))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Neo.onAccent(Neo.purple, scheme: scheme).opacity(0.12)))
        .overlay(
            Capsule().stroke(
                Neo.onAccent(Neo.purple, scheme: scheme).opacity(0.22),
                lineWidth: 1))
    }
}

// MARK: - Cached poster

/// Once a file has been previewed, the grid can show a real frame instead of
/// the tinted placeholder. Photos load directly; videos yield their first
/// playable frame. Everything is local — no extra Telegram requests.
struct TelegramPosterThumb: View {
    var url: URL?
    var kind: TelegramPreviewKind?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            switch kind {
            case .photo:
                image = NSImage(contentsOf: url)
            case .video:
                image = await Self.videoFrame(url)
            default:
                image = nil
            }
        }
    }

    private static func videoFrame(_ url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 420)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: result.image, size: .zero)
    }
}
