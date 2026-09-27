import Foundation

public enum AudioConverterError: Error, LocalizedError {
    case binaryMissing(expectedPath: String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return "Audio converter binary not found at \(path)"
        case .conversionFailed(let message):
            return message
        }
    }
}

/// Extracts audio tracks to MP3 via a bundled ffmpeg. DOCUMENTED STUB: throws
/// `.binaryMissing` until the binary is wired in a later milestone.
public final class AudioConverter {
    public init() {}

    /// The bundled binary ships at `<App>.app/Contents/Resources/bin/ffmpeg`.
    private var binaryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg")
    }

    public func extractMP3(from source: URL, to destination: URL, progress: (Double) -> Void) async throws {
        // Intended wiring (not yet connected — the binary ships in a later milestone):
        //   <bundle>/bin/ffmpeg -i "<source.path>" -vn -codec:a libmp3lame -q:a 2 "<destination.path>"
        // Drive `progress` by parsing ffmpeg's stderr:
        //   1. Read the "Duration: 00:03:12.45" line for the total.
        //   2. Parse "time=00:01:02.10" updates -> progress = time / duration.
        // Run via Process with pipes; support cooperative cancellation by
        // terminating the process when the enclosing Task is cancelled.
        let expected = binaryURL?.path ?? "<bundle>/bin/ffmpeg"
        throw AudioConverterError.binaryMissing(expectedPath: expected)
    }
}
