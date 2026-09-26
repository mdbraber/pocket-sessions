import Foundation

/// Fork: Pocket Casts web links (pca.st, pocketcasts.com) can't open this self-built app as universal
/// links — only the official app can claim those domains. The share sheet and the Safari extension hand
/// them over as `pktc://weblink/<https URL>` instead; this parses those URLs.
///
/// Compiled into both the app and the Share Extension, so it must only depend on Foundation.
enum PocketCastsWebLink {
    static let hosts: Set<String> = ["pca.st", "pocketcasts.com", "www.pocketcasts.com", "play.pocketcasts.com"]

    static let weblinkPrefix = "pktc://weblink/"

    /// Whether `host` is a Pocket Casts web host. `extraHosts` adds hosts only the app knows,
    /// such as the staging share host.
    static func isPocketCastsHost(_ host: String?, extraHosts: [String] = []) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains(host) || extraHosts.contains { $0.lowercased() == host }
    }

    /// The https Pocket Casts URL carried by `pktc://weblink/<url>`, or nil when `url` isn't a weblink
    /// or carries anything else. The web URL may be raw (`https://pca.st/…?t=1`) or percent-encoded
    /// once (`https%3A%2F%2Fpca.st%2F…`).
    static func webURL(fromPktcWeblink url: URL, extraHosts: [String] = []) -> URL? {
        guard url.scheme?.lowercased() == "pktc", url.host?.lowercased() == "weblink" else { return nil }

        let string = url.absoluteString
        guard let prefixRange = string.range(of: weblinkPrefix, options: [.caseInsensitive, .anchored]) else { return nil }

        var target = String(string[prefixRange.upperBound...])
        if target.lowercased().hasPrefix("https%3a") {
            guard let decoded = target.removingPercentEncoding else { return nil }
            target = decoded
        }

        guard
            let webURL = URL(string: target),
            webURL.scheme?.lowercased() == "https",
            webURL.user == nil,
            webURL.password == nil,
            isPocketCastsHost(webURL.host, extraHosts: extraHosts)
        else { return nil }

        return webURL
    }

    /// The podcast UUID from `pktc://podcast/<uuid>`, or nil.
    static func podcastUuid(fromPktcPodcast url: URL) -> String? {
        guard url.scheme?.lowercased() == "pktc", url.host?.lowercased() == "podcast" else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let uuid = components.first, !uuid.isEmpty else { return nil }

        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard uuid.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return uuid
    }
}
