import Foundation

/// Rewrites share links into direct download URLs (QDM `rewrite_download_url`
/// idea). Users paste share links constantly; resolving them to direct links
/// before probing means the engine always works with the real file URL.
enum ShareURLRewriter {
    static func rewrite(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return url }

        if host.hasSuffix("dropbox.com") {
            // https://www.dropbox.com/s/<id>/<name>?dl=0 -> dl=1 (direct).
            setQueryItem(&components, name: "dl", value: "1")
        } else if host == "drive.google.com" {
            // https://drive.google.com/file/d/<id>/view -> uc?export=download.
            let parts = components.path.split(separator: "/")
            if parts.count >= 3, parts[0] == "file", parts[1] == "d" {
                let id = String(parts[2])
                components.path = "/uc"
                components.queryItems = [
                    URLQueryItem(name: "id", value: id),
                    URLQueryItem(name: "export", value: "download"),
                ]
            }
        } else if host.hasSuffix("1drv.ms") || host.hasSuffix("onedrive.live.com")
            || host.hasSuffix("sharepoint.com")
        {
            // OneDrive/SharePoint shared links honour download=1.
            setQueryItem(&components, name: "download", value: "1")
        }

        return components.url ?? url
    }

    private static func setQueryItem(
        _ components: inout URLComponents, name: String, value: String
    ) {
        var items = components.queryItems ?? []
        if let i = items.firstIndex(where: { $0.name == name }) {
            items[i].value = value
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
    }
}
