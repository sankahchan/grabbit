import Foundation

/// Heuristic detection of signed / expiring download URLs (QDM `is_signed_url`
/// idea). When a download fails with 403/410 on one of these, the link itself
/// has expired — retrying the same URL is pointless. The engine surfaces a
/// distinct `linkExpired` state instead of a generic failure.
///
/// Matching is done on query *parameter names* (case-insensitive), not raw
/// substrings: naive substring matching on e.g. "e=" false-positives on
/// "?name=x".
enum SignedURLDetector {
    /// Query parameter names that indicate a signed, expiring URL.
    private static let signedParameters: Set<String> = [
        "x-amz-signature", "x-amz-expires", "x-amz-credential", "x-amz-date",
        "x-goog-signature", "x-goog-expires",
        "signature", "sig", "se", "st", "expires", "expiry", "exp",
        "token", "access_token", "auth", "key",
    ]

    static func isSigned(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return false }
        return items.contains { signedParameters.contains($0.name.lowercased()) }
    }
}
