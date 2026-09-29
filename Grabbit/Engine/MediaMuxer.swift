import Foundation

/// Muxes a captured video-only track and its separate audio track back into
/// one file with the bundled ffmpeg (`-c copy`, no re-encode).
///
/// Telegram Web's MSE player can hand us two independent fMP4 tracks (video
/// SourceBuffer + audio SourceBuffer); the native helper writes them as two
/// files and the import path calls this to stitch them together. Pure arg
/// builder is unit-tested; the actual run uses `ManagedProcess`.
public enum MediaMuxer {
    public enum MuxError: Error, LocalizedError {
        case ffmpegUnavailable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .ffmpegUnavailable:
                return NSLocalizedString("mux.error.ffmpegUnavailable", comment: "")
            case .failed(let detail):
                return detail
            }
        }
    }

    /// ffmpeg arguments for a stream-copy mux. `-movflags +faststart` so the
    /// moov atom lands at the front (streamable/quicklook-friendly MP4).
    public static func arguments(video: URL, audio: URL, output: URL) -> [String] {
        [
            "-y",
            "-i", video.path,
            "-i", audio.path,
            "-c", "copy",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    /// Muxes `audio` into `video`, writing the combined file to `output`.
    /// The caller owns cleanup of the inputs.
    public static func mux(video: URL, audio: URL, output: URL) async -> Result<Void, Error> {
        guard case .success(let ffmpeg) = MediaRuntimeResolver.resolve(.ffmpeg) else {
            return .failure(MuxError.ffmpegUnavailable)
        }
        let process = ManagedProcess()
        let result = await process.run(
            executable: ffmpeg,
            arguments: arguments(video: video, audio: audio, output: output))
        guard !result.wasCancelled, result.exitCode == 0,
              FileManager.default.fileExists(atPath: output.path)
        else {
            let detail = result.stderrTail.split(separator: "\n").last.map(String.init)
                ?? "ffmpeg exited with code \(result.exitCode)"
            return .failure(MuxError.failed(detail))
        }
        return .success(())
    }
}
