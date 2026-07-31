import Foundation
import PocketCastsUtils

/// Fork: routes Pocket Casts API traffic through the self-hosted sessions server (PCS).
///
/// PCS exposes a transparent relay at `<sessionServer>/pcapi/*` that forwards bytes verbatim to
/// `api.pocketcasts.com` and back, so it can keep a server-side replica of the sync data. Nothing
/// about the app's behaviour changes — this is a pure transport swap.
///
/// **Scope.** ONLY `api.pocketcasts.com`. The cache server, the podcast catalogue, the refresh
/// service and all media/CDN traffic go direct, because the relay does not front them and sending
/// them there would break them. `shouldRelay` is the single place that decides.
///
/// **Where it applies.** `PCAPIRelayURLProtocol` rewrites requests as they are sent rather than
/// where they are built. Requests are constructed in dozens of places from `ServerConstants.Urls`
/// and from a handful of hardcoded strings; intercepting at the loading system catches all of them,
/// including any added later, and is the only point where the fallback below can retry a request
/// that has already left its call site.
public enum PCAPIRelay {
    /// What the app has to supply for relaying to be possible at all.
    public struct Config: Equatable {
        public let baseURL: URL
        public let token: String

        public init(baseURL: URL, token: String) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    /// The header PCS authenticates the relay with. The `Authorization` header (the Pocket Casts
    /// token) is left untouched and passes through to the origin.
    public static let proxyTokenHeader = "X-PCS-Proxy-Token"

    /// Marks a request this protocol has already taken, so the retry it issues isn't intercepted
    /// again and looped.
    static let handledKey = "PCAPIRelayHandled"

    /// The host the relay fronts. Nothing else is ever rewritten.
    static let relayedHost = "api.pocketcasts.com"

    // MARK: - Configuration

    private static let lock = NSLock()
    private static var config: Config?

    /// Registers the interception. Idempotent, and safe to call before any config exists — with no
    /// config `canInit` declines every request, so the loading system behaves exactly as before.
    public static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        URLProtocol.registerClass(PCAPIRelayURLProtocol.self)
    }

    private static var isInstalled = false

    /// Set by the app whenever the toggle, the server URL or the token changes. Reads happen per
    /// request, so a change applies to the next request with no restart.
    public static func configure(_ config: Config?) {
        lock.lock()
        defer { lock.unlock() }
        let changed = Self.config != config
        Self.config = config
        if changed {
            consecutiveFailures = 0
            bypassUntil = nil
            FileLog.shared.addMessage("PCAPIRelay: \(config == nil ? "off" : "on (\(config!.baseURL.absoluteString))")")
        }
    }

    /// nil when relaying is off, unconfigured, or currently bypassed after repeated failures.
    static func activeConfig() -> Config? {
        lock.lock()
        defer { lock.unlock() }
        guard let config else { return nil }
        if let until = bypassUntil {
            if Date() < until { return nil }
            // The bypass window has passed — try the relay again from a clean slate.
            bypassUntil = nil
            consecutiveFailures = 0
        }
        return config
    }

    public static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config != nil
    }

    // MARK: - Health

    /// After this many consecutive transport failures the relay is skipped for `bypassDuration`,
    /// so a server that is down costs one failed attempt per window rather than one per request.
    static let failureThreshold = 3
    static let bypassDuration: TimeInterval = 10.minutes

    private static var consecutiveFailures = 0
    private static var bypassUntil: Date?

    static func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures += 1
        guard consecutiveFailures >= failureThreshold, bypassUntil == nil else { return }
        bypassUntil = Date().addingTimeInterval(bypassDuration)
        FileLog.shared.addMessage("PCAPIRelay: \(consecutiveFailures) consecutive failures — going direct for \(Int(bypassDuration / 60)) minutes")
    }

    static func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
    }

    /// Test seam: forget any accumulated health state.
    static func resetHealth() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
        bypassUntil = nil
    }

    // MARK: - Rewriting

    /// Whether this request should go through the relay.
    static func shouldRelay(_ request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil,
              let host = request.url?.host else { return false }
        return host.caseInsensitiveCompare(relayedHost) == .orderedSame
    }

    /// The relayed form of a direct API request: same path, query and body, pointed at
    /// `<server>/pcapi/<path>` with the proxy token attached.
    static func relayed(_ request: URLRequest, config: Config) -> URLRequest? {
        guard let original = request.url,
              var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { return nil }

        // `api.pocketcasts.com/user/login` -> `<server>/pcapi/user/login`. The server's own base may
        // itself have a path prefix, so build on it rather than replacing it.
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/pcapi" + original.path
        components.query = original.query
        components.fragment = original.fragment
        guard let relayedURL = components.url else { return nil }

        var relayedRequest = request
        relayedRequest.url = relayedURL
        relayedRequest.setValue(config.token, forHTTPHeaderField: proxyTokenHeader)
        return relayedRequest
    }
}
