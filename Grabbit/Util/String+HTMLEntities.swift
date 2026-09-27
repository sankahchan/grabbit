import Foundation

extension String {
    /// Decodes HTML entities: `&amp;`, `&ndash;`, `&#8211;`, `&#x2013;`, …
    ///
    /// Magnet `dn` params and scraped media titles often carry raw entities
    /// (e.g. `DDG &ndash; HIT-A-THON`). Unknown or malformed entities are
    /// left untouched. Pure — tested.
    public var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var i = startIndex
        while i < endIndex {
            guard self[i] == "&" else {
                result.append(self[i])
                i = index(after: i)
                continue
            }
            // Entities are short; bound the scan so a stray "&" in a long
            // string can't cause a quadratic scan.
            let searchEnd = index(i, offsetBy: 12, limitedBy: endIndex) ?? endIndex
            if let semi = self[i..<searchEnd].firstIndex(of: ";") {
                let entity = String(self[index(after: i)..<semi])
                if let decoded = Self.decodeHTMLEntity(entity) {
                    result.append(contentsOf: decoded)
                    i = index(after: semi)
                    continue
                }
            }
            result.append(self[i])
            i = index(after: i)
        }
        return result
    }

    private static func decodeHTMLEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            guard let code = UInt32(entity.dropFirst(2), radix: 16),
                  let scalar = UnicodeScalar(code) else { return nil }
            return String(scalar)
        }
        if entity.hasPrefix("#") {
            guard let code = UInt32(entity.dropFirst()),
                  let scalar = UnicodeScalar(code) else { return nil }
            return String(scalar)
        }
        return namedHTMLEntities[entity]
    }

    /// Common named entities (not exhaustive — exotic ones are rare in
    /// torrent/media names and safely left as-is).
    private static let namedHTMLEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
        "trade": "™", "middot": "·", "bull": "•", "deg": "°",
        "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "times": "×", "divide": "÷", "euro": "€", "pound": "£", "yen": "¥",
    ]
}
