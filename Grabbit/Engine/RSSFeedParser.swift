import Foundation

/// Minimal RSS 2.0 / Atom parser for subscription polling: the feed title
/// plus per-item title, link, guid/id, enclosure and publication date.
/// Deliberately small — no third-party dependency, no full feed-spec
/// coverage; anything it misses simply doesn't download.
final class RSSFeedParser: NSObject, XMLParserDelegate {
    struct Result {
        var title: String
        var items: [RSSItem]
    }

    static func parse(data: Data) -> Result {
        let delegate = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Result(title: delegate.feedTitle, items: delegate.items)
    }

    private var feedTitle = ""
    private var items: [RSSItem] = []
    private var inItem = false
    private var buffer = ""

    private var itemTitle = ""
    private var itemLink = ""
    private var itemID = ""
    private var itemEnclosure: String?
    private var itemEnclosureType: String?
    private var itemDate: Date?

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    private static func date(from raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = iso8601.date(from: text) { return date }
        if let date = rfc822.date(from: text) { return date }
        // RFC 822 with a named zone ("GMT") or a missing weekday.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return fallback.date(from: text)
    }

    private func localName(_ element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        let name = localName(elementName)
        if name == "item" || name == "entry" {
            inItem = true
            itemTitle = ""
            itemLink = ""
            itemID = ""
            itemEnclosure = nil
            itemEnclosureType = nil
            itemDate = nil
            return
        }
        guard inItem else { return }
        if name == "enclosure", let url = attributeDict["url"] {
            itemEnclosure = url
            itemEnclosureType = attributeDict["type"]
            return
        }
        if name == "link", let href = attributeDict["href"] {
            // Atom: rel="enclosure" is the media; everything else (or no
            // rel) is the alternate page link.
            let rel = attributeDict["rel"]?.lowercased()
            if rel == "enclosure" {
                itemEnclosure = href
                itemEnclosureType = attributeDict["type"]
            } else if rel == nil || rel == "alternate" {
                itemLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""

        if name == "item" || name == "entry" {
            inItem = false
            let id = !itemID.isEmpty ? itemID : (!itemLink.isEmpty ? itemLink : itemTitle)
            guard !id.isEmpty else { return }
            items.append(RSSItem(
                id: id,
                title: itemTitle,
                link: itemLink,
                enclosureURL: itemEnclosure,
                enclosureType: itemEnclosureType,
                publishedAt: itemDate))
            return
        }

        if inItem {
            switch name {
            case "title":
                if itemTitle.isEmpty { itemTitle = text }
            case "link":
                if itemLink.isEmpty { itemLink = text } // RSS text form
            case "guid", "id":
                if itemID.isEmpty { itemID = text }
            case "pubDate", "published", "updated":
                if itemDate == nil { itemDate = Self.date(from: text) }
            default:
                break
            }
            return
        }

        // Channel/feed level: the first title is the feed's own name.
        if name == "title", feedTitle.isEmpty {
            feedTitle = text
        }
    }
}
