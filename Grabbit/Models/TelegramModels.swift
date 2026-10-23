import Foundation

/// One Telegram dialog (user, group or channel) shown in the browser sidebar.
struct TelegramChat: Identifiable, Codable, Hashable, Sendable {
    let id: Int64
    let title: String
    let username: String?
    let kind: String

    /// The account's own Saved Messages space. Telegram does not return it in
    /// the dialog list, so the app pins it as a synthetic first entry — it is
    /// always safe to browse and download from, no third party involved.
    static let savedMessages = TelegramChat(
        id: 0, title: "Saved Messages", username: nil, kind: "self")

    /// UI title. The synthetic Saved Messages row is localized at render
    /// time, while `title` stays stable for folder names and history.
    var displayTitle: String {
        if kind == "self" {
            return NSLocalizedString("telegram.savedMessages", comment: "")
        }
        return title
    }

    var peerArgument: String {
        if kind == "self" { return "self" }
        if let username, !username.isEmpty { return "@\(username)" }
        // IDs overlap between users, basic groups, and channels. Keep the
        // peer type in the argument so the helper cannot resolve a different
        // dialog that happens to share the same numeric id.
        return "\(kind):\(id)"
    }

    var subtitle: String {
        if let username, !username.isEmpty { return "@\(username)" }
        switch kind {
        case "user", "self":
            return NSLocalizedString("telegram.chat.private", comment: "")
        case "group":
            return NSLocalizedString("telegram.chat.group", comment: "")
        case "channel":
            return NSLocalizedString("telegram.chat.channel", comment: "")
        default:
            return kind.capitalized
        }
    }

    var icon: String {
        switch kind {
        case "user": "person.crop.circle"
        case "self": "bookmark"
        case "group": "person.3"
        case "channel": "megaphone"
        default: "bubble.left.and.bubble.right"
        }
    }
}

/// How a media message can be shown in the in-app viewer. This is a display
/// classification, not Telegram's own media kind: a PNG sent as a document
/// is still a photo to the user.
enum TelegramPreviewKind: String, Sendable {
    case photo
    case video
    case audio

    var label: String {
        switch self {
        case .photo: NSLocalizedString("telegram.media.photo", comment: "")
        case .video: NSLocalizedString("telegram.media.video", comment: "")
        case .audio: NSLocalizedString("telegram.media.audio", comment: "")
        }
    }
}

/// One media-bearing Telegram message. Text-only messages are filtered out
/// by the helper so the browser only shows download candidates.
struct TelegramMessage: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let date: Int
    let text: String?
    let mediaKind: String?
    let fileName: String?
    let mimeType: String?
    let size: Int64?
    let duration: Int?
    let width: Int?
    let height: Int?
    let canDownload: Bool

    var displayName: String {
        let base: String
        if let fileName, !fileName.isEmpty {
            base = fileName
        } else {
            base = "Telegram \(mediaKind ?? "file") \(id)"
        }
        // Native videos and voice notes often arrive without a filename, and
        // the helper's document fallback has no extension either.
        guard (base as NSString).pathExtension.isEmpty,
              let ext = inferredExtension else { return base }
        return "\(base).\(ext)"
    }

    /// Telegram does not always report a filename (native videos, voice
    /// notes, some uploads). Cache paths and Downloads still need an extension
    /// so NSImage/AVFoundation can pick the right decoder and Finder can open
    /// the file. Only infer for the media types the helper actually reports.
    private var inferredExtension: String? {
        switch (mimeType ?? "").lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/mp4a-latm", "audio/aac", "audio/x-m4a": return "m4a"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        default: break
        }
        switch mediaKind {
        case "photo": return "jpg"
        case "video", "gif": return "mp4"
        case "audio": return "m4a"
        default: return nil
        }
    }

    var icon: String {
        switch previewKind {
        case .video: return "film"
        case .photo: return "photo"
        case .audio: return "waveform"
        case nil: break
        }
        switch mediaKind {
        case "sticker": return "face.smiling"
        default: return "doc"
        }
    }

    var dateValue: Date { Date(timeIntervalSince1970: TimeInterval(date)) }
    var sizeValue: Int64 { size ?? 0 }

    /// What the viewer can render, decided from the descriptor first and the
    /// filename extension second. The helper reports real MIME types, but
    /// older uploads (and Telegram photos) can be sparse — never assume a
    /// file is previewable just because it has a friendly extension.
    var previewKind: TelegramPreviewKind? {
        switch mediaKind {
        case "photo": return .photo
        case "video", "gif": return .video
        case "audio": return .audio
        // Stickers are images to Telegram, but they are not part of the
        // photo library and NSImage cannot animate them. Keep them as files.
        case "sticker": return nil
        default: break
        }

        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("image/") { return .photo }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }

        let ext = (displayName as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff", "gif"].contains(ext) {
            return .photo
        }
        if ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext) {
            return .video
        }
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) {
            return .audio
        }
        return nil
    }

    var isPreviewable: Bool { previewKind != nil }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var dimensionsText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

enum TelegramMediaFilter: String, CaseIterable, Identifiable {
    case all
    case video
    case photo
    case audio
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: NSLocalizedString("telegram.filter.all", comment: "")
        case .video: NSLocalizedString("telegram.filter.video", comment: "")
        case .photo: NSLocalizedString("telegram.filter.photo", comment: "")
        case .audio: NSLocalizedString("telegram.filter.audio", comment: "")
        case .file: NSLocalizedString("telegram.filter.file", comment: "")
        }
    }

    func matches(_ message: TelegramMessage) -> Bool {
        switch self {
        case .all:
            return true
        case .video:
            return message.previewKind == .video
        case .photo:
            return message.previewKind == .photo
        case .audio:
            return message.previewKind == .audio
        case .file:
            // A document is only a "file" if the viewer cannot render it.
            return message.previewKind == nil
        }
    }
}
