import Foundation
import PocketCastsUtils

/// Fork: sends Pocket Casts API requests through the PCS relay, with a direct fallback.
///
/// A `URLProtocol` rather than a change at each call site. API requests are built in dozens of
/// places — `ServerConstants.Urls.api()` has ~58 callers plus a few hardcoded strings — and the
/// fallback has to be able to re-issue a request *after* it has failed, which no call site is in a
/// position to do. Intercepting at the loading system is the only point that sees every request and
/// still owns the retry.
///
/// **The fallback is deliberately narrow.** It retries directly against `api.pocketcasts.com` only
/// when the RELAY ITSELF failed to carry the request: a transport error (refused, timed out, DNS)
/// or a 5xx produced by the relay. A 4xx or 5xx that the relay faithfully carried back FROM Pocket
/// Casts is a real answer to a real request and is returned untouched — retrying those would turn
/// one rejected login into two, and could double-apply a non-idempotent write.
final class PCAPIRelayURLProtocol: URLProtocol {
    /// Named to avoid `URLProtocol.task`, which already exists and is read-only.
    private var relayTask: URLSessionDataTask?

    /// Its own session, so this protocol is not registered on it and the requests it makes are not
    /// intercepted again.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        PCAPIRelay.shouldRelay(request) && PCAPIRelay.activeConfig() != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let config = PCAPIRelay.activeConfig(),
              let relayed = PCAPIRelay.relayed(request, config: config) else {
            send(request, viaRelay: false)
            return
        }
        send(relayed, viaRelay: true)
    }

    private func send(_ request: URLRequest, viaRelay: Bool) {
        // Mark it so `canInit` declines this one, and the direct retry below cannot recurse.
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: PCAPIRelay.handledKey, in: mutable)
        let outgoing = mutable as URLRequest

        relayTask = Self.session.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }

            if viaRelay, self.relayItselfFailed(response: response, error: error) {
                PCAPIRelay.recordFailure()
                FileLog.shared.addMessage("PCAPIRelay: relay failed for \(self.request.url?.path ?? "?") — retrying direct")
                self.send(self.request, viaRelay: false) // the ORIGINAL, unrewritten request
                return
            }

            if viaRelay { PCAPIRelay.recordSuccess() }

            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        relayTask?.resume()
    }

    /// Whether the RELAY failed to carry the request, as opposed to Pocket Casts answering it badly.
    ///
    /// A transport error means we never got an answer at all. A 502/503/504 is the shape a proxy
    /// reports when its upstream is unreachable — and PCS's own handler failing produces a 5xx too.
    /// Anything else, including a relayed 401 or a relayed 500 from Pocket Casts, is left alone.
    private func relayItselfFailed(response: URLResponse?, error: Error?) -> Bool {
        if error != nil { return true }
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode >= 500
    }

    override func stopLoading() {
        relayTask?.cancel()
        relayTask = nil
    }
}
