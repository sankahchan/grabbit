import XCTest
@testable import Grabbit

final class TelegramModelTests: XCTestCase {

    private func message(
        id: Int = 1,
        mediaKind: String?,
        fileName: String? = nil,
        mimeType: String? = nil,
        duration: Int? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) -> TelegramMessage {
        TelegramMessage(
            id: id,
            date: 1_700_000_000,
            text: nil,
            mediaKind: mediaKind,
            fileName: fileName,
            mimeType: mimeType,
            size: 1_024,
            duration: duration,
            width: width,
            height: height,
            canDownload: true)
    }

    func testNativeTelegramKindsArePreviewable() {
        XCTAssertEqual(message(mediaKind: "photo").previewKind, .photo)
        XCTAssertEqual(message(mediaKind: "video").previewKind, .video)
        XCTAssertEqual(message(mediaKind: "gif").previewKind, .video)
        XCTAssertEqual(message(mediaKind: "audio").previewKind, .audio)
        XCTAssertNil(message(mediaKind: "sticker").previewKind)
        // Real stickers report image/webp MIME; they must not leak into the
        // photo library just because their payload is an image.
        XCTAssertNil(message(mediaKind: "sticker", mimeType: "image/webp").previewKind)
    }

    func testDocumentsUseMIMETypeBeforeExtension() {
        // Telegram uploads with ForceFile arrive as `document` even when the
        // payload is a normal photo or clip; MIME must win.
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "clip.bin", mimeType: "video/mp4").previewKind,
            .video)
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "photo.bin", mimeType: "image/png").previewKind,
            .photo)
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "track.bin", mimeType: "audio/mp4a-latm").previewKind,
            .audio)
    }

    func testExtensionlessMediaGetsAnExtensionForCacheAndDownloads() {
        // The helper's document fallback is intentionally extensionless, and
        // native videos are not guaranteed a filename at all.
        XCTAssertEqual(
            message(mediaKind: "video", fileName: "telegram-document-1", mimeType: "video/mp4").displayName,
            "telegram-document-1.mp4")
        XCTAssertEqual(
            message(mediaKind: "audio", mimeType: "audio/ogg").displayName,
            "Telegram audio 1.ogg")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "telegram-document-2", mimeType: "image/png").displayName,
            "telegram-document-2.png")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "archive", mimeType: "application/zip").displayName,
            "archive")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "report.pdf", mimeType: "application/pdf").displayName,
            "report.pdf")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "clip.MOV", mimeType: "video/quicktime").displayName,
            "clip.MOV")
    }

    func testDocumentsFallBackToFilenameExtension() {
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "grabbit-preview.png").previewKind,
            .photo)
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "grabbit-preview.MP4").previewKind,
            .video)
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "grabbit-preview.m4a").previewKind,
            .audio)
        XCTAssertNil(message(mediaKind: "document", fileName: "archive.zip").previewKind)
    }

    func testFilterClassifiesDocumentMediaByPreviewKind() {
        let photo = message(id: 1, mediaKind: "document", fileName: "a.png", mimeType: "image/png")
        let video = message(id: 2, mediaKind: "document", fileName: "b.mp4", mimeType: "video/mp4")
        let audio = message(id: 3, mediaKind: "document", fileName: "c.m4a", mimeType: "audio/mp4")
        let file = message(id: 4, mediaKind: "document", fileName: "d.pdf", mimeType: "application/pdf")

        XCTAssertTrue(TelegramMediaFilter.photo.matches(photo))
        XCTAssertFalse(TelegramMediaFilter.file.matches(photo))
        XCTAssertTrue(TelegramMediaFilter.video.matches(video))
        XCTAssertFalse(TelegramMediaFilter.file.matches(video))
        XCTAssertTrue(TelegramMediaFilter.audio.matches(audio))
        XCTAssertFalse(TelegramMediaFilter.file.matches(audio))
        XCTAssertTrue(TelegramMediaFilter.file.matches(file))
        XCTAssertFalse(TelegramMediaFilter.photo.matches(file))
    }

    func testEveryMessageMatchesExactlyOneConcreteFilter() {
        let samples: [TelegramMessage] = [
            message(id: 1, mediaKind: "photo"),
            message(id: 2, mediaKind: "video"),
            message(id: 3, mediaKind: "audio"),
            message(id: 4, mediaKind: "document", fileName: "a.png", mimeType: "image/png"),
            message(id: 5, mediaKind: "document", fileName: "b.mp4", mimeType: "video/mp4"),
            message(id: 6, mediaKind: "document", fileName: "c.m4a", mimeType: "audio/mp4"),
            message(id: 7, mediaKind: "document", fileName: "d.pdf", mimeType: "application/pdf"),
            message(id: 8, mediaKind: "sticker"),
        ]
        let concrete: [TelegramMediaFilter] = [.video, .photo, .audio, .file]

        for sample in samples {
            let matches = concrete.filter { $0.matches(sample) }
            XCTAssertEqual(
                matches.count, 1,
                "message \(sample.id) matched \(matches.map(\.rawValue))")
            XCTAssertTrue(TelegramMediaFilter.all.matches(sample))
        }
    }

    func testIconPrefersPreviewKindForDocumentMedia() {
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "a.png", mimeType: "image/png").icon,
            "photo")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "b.mp4", mimeType: "video/mp4").icon,
            "film")
        XCTAssertEqual(
            message(mediaKind: "document", fileName: "c.m4a", mimeType: "audio/mp4").icon,
            "waveform")
        XCTAssertEqual(message(mediaKind: "document", fileName: "d.pdf").icon, "doc")
        XCTAssertEqual(message(mediaKind: "sticker").icon, "face.smiling")
    }

    func testMediaDetailTextOmitsUnknownValues() {
        let described = message(
            mediaKind: "video", duration: 3_725, width: 1_080, height: 1_920)
        XCTAssertEqual(described.durationText, "1:02:05")
        XCTAssertEqual(described.dimensionsText, "1080×1920")

        let sparse = message(mediaKind: "document", fileName: "a.png")
        XCTAssertNil(sparse.durationText)
        XCTAssertNil(sparse.dimensionsText)
    }

    func testAuthorizedStatusRequiresAnExactLine() {
        XCTAssertTrue(TelegramService.isAuthorizedStatus("AUTHORIZED\n"))
        XCTAssertTrue(TelegramService.isAuthorizedStatus("SELF\t1\tname\tuser\nAUTHORIZED\r\n"))
        XCTAssertFalse(TelegramService.isAuthorizedStatus("UNAUTHORIZED\n"))
        XCTAssertFalse(TelegramService.isAuthorizedStatus("NOT_AUTHORIZED\n"))
        XCTAssertFalse(TelegramService.isAuthorizedStatus(""))
    }

    func testSafeNameStripsPathAndProtocolControlCharacters() {
        XCTAssertEqual(
            TelegramService.safeName("clip\tQUIT\nname.mp4"),
            "clip_QUIT_name.mp4")
        XCTAssertEqual(
            TelegramService.safeName("a/b:c\\d?e%f*g|h\"i<j>k"),
            "a_b_c_d_e_f_g_h_i_j_k")
        XCTAssertEqual(TelegramService.safeName("  ..  "), "telegram-file")
    }

    func testSafeNameClipsLongNamesWithoutLosingTheExtension() {
        let long = String(repeating: "x", count: 400) + ".mp4"
        let clipped = TelegramService.safeName(long)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 180)
        XCTAssertTrue(clipped.hasSuffix(".mp4"))
    }

    func testSafeNameClipsPathologicalExtensions() {
        let long = String(repeating: "x", count: 300)
            + "."
            + String(repeating: "y", count: 300)
        let clipped = TelegramService.safeName(long)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 180)
    }

    func testSavedMessagesDisplayTitleUsesLocalizedString() {
        XCTAssertEqual(
            TelegramChat.savedMessages.displayTitle,
            NSLocalizedString("telegram.savedMessages", comment: ""))
    }

    func testPeerArgumentsDisambiguateNumericPeerTypes() {
        XCTAssertEqual(
            TelegramChat(id: 7, title: "Private", username: nil, kind: "user").peerArgument,
            "user:7")
        XCTAssertEqual(
            TelegramChat(id: 7, title: "Group", username: nil, kind: "group").peerArgument,
            "group:7")
        XCTAssertEqual(
            TelegramChat(id: 7, title: "Channel", username: nil, kind: "channel").peerArgument,
            "channel:7")
        XCTAssertEqual(
            TelegramChat(id: 7, title: "Public", username: "public_name", kind: "channel").peerArgument,
            "@public_name")
        XCTAssertEqual(TelegramChat.savedMessages.peerArgument, "self")
    }
}
