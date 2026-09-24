@testable import PocketCastsServer
@testable import podcasts
import XCTest

/// Fork: the relay silently changes where every sync request goes, so the two rules that keep it
/// safe are worth pinning — WHICH hosts it touches, and WHEN it is allowed to retry.
final class PCAPIRelayTests: XCTestCase {
    private let config = PCAPIRelay.Config(baseURL: URL(string: "https://pcs.example.org")!, token: "tok-123")

    private func request(_ url: String) -> URLRequest {
        URLRequest(url: URL(string: url)!)
    }

    override func tearDown() {
        PCAPIRelay.configure(nil)
        PCAPIRelay.resetHealth()
        super.tearDown()
    }

    // MARK: - Scope: only api.pocketcasts.com

    func testRelaysTheApiHost() {
        XCTAssertTrue(PCAPIRelay.shouldRelay(request("https://api.pocketcasts.com/user/login")))
    }

    func testLeavesEveryOtherPocketCastsHostAlone() {
        // The relay fronts only the API. Sending these through it would break them outright, since
        // it has no route for them.
        for url in [
            "https://cache.pocketcasts.com/mobile/podcast/full/abc",
            "https://podcast-api.pocketcasts.com/podcast/full/abc",
            "https://refresh.pocketcasts.com/user/update",
            "https://static.pocketcasts.com/discover/images/280/abc.jpg",
            "https://sharing.pocketcasts.com/x",
            "https://files.pocketcasts.com/files/abc"
        ] {
            XCTAssertFalse(PCAPIRelay.shouldRelay(request(url)), "\(url) must go direct")
        }
    }

    func testDoesNotRelayALookalikeHost() {
        // Suffix matching would send traffic to an attacker's host; the comparison is exact.
        XCTAssertFalse(PCAPIRelay.shouldRelay(request("https://api.pocketcasts.com.evil.test/user/login")))
        XCTAssertFalse(PCAPIRelay.shouldRelay(request("https://notapi.pocketcasts.com/user/login")))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(PCAPIRelay.shouldRelay(request("https://API.PocketCasts.com/user/login")))
    }

    // MARK: - Rewriting

    func testRewritesPathOntoTheRelayAndAddsTheToken() {
        let relayed = PCAPIRelay.relayed(request("https://api.pocketcasts.com/user/login"), config: config)
        XCTAssertEqual(relayed?.url?.absoluteString, "https://pcs.example.org/pcapi/user/login")
        XCTAssertEqual(relayed?.value(forHTTPHeaderField: PCAPIRelay.proxyTokenHeader), "tok-123")
    }

    func testPreservesTheQueryString() {
        let relayed = PCAPIRelay.relayed(request("https://api.pocketcasts.com/files/url/abc?token=xyz&v=2"), config: config)
        XCTAssertEqual(relayed?.url?.absoluteString, "https://pcs.example.org/pcapi/files/url/abc?token=xyz&v=2")
    }

    func testLeavesTheAuthorizationHeaderUntouched() {
        // The PC token is the origin's business — the relay passes it through and authenticates
        // itself with its own header.
        var original = request("https://api.pocketcasts.com/user/login")
        original.setValue("Bearer pc-token", forHTTPHeaderField: "Authorization")
        let relayed = PCAPIRelay.relayed(original, config: config)
        XCTAssertEqual(relayed?.value(forHTTPHeaderField: "Authorization"), "Bearer pc-token")
    }

    func testPreservesMethodAndBody() {
        var original = request("https://api.pocketcasts.com/sync/update")
        original.httpMethod = "POST"
        original.httpBody = Data([0x08, 0x96, 0x01])
        let relayed = PCAPIRelay.relayed(original, config: config)
        XCTAssertEqual(relayed?.httpMethod, "POST")
        XCTAssertEqual(relayed?.httpBody, Data([0x08, 0x96, 0x01]))
    }

    func testHonoursAPathPrefixOnTheServerURL() {
        // A server hosted under a sub-path must keep it, rather than having /pcapi replace it.
        let prefixed = PCAPIRelay.Config(baseURL: URL(string: "https://example.org/pcs/")!, token: "t")
        let relayed = PCAPIRelay.relayed(request("https://api.pocketcasts.com/user/login"), config: prefixed)
        XCTAssertEqual(relayed?.url?.absoluteString, "https://example.org/pcs/pcapi/user/login")
    }

    // MARK: - Enablement

    func testNoConfigMeansNoRelay() {
        PCAPIRelay.configure(nil)
        XCTAssertNil(PCAPIRelay.activeConfig())
        XCTAssertFalse(PCAPIRelay.isEnabled)
    }

    func testConfigTakesEffectImmediately() {
        // The toggle has to apply without a restart, so the config is read per request.
        PCAPIRelay.configure(config)
        XCTAssertNotNil(PCAPIRelay.activeConfig())
        PCAPIRelay.configure(nil)
        XCTAssertNil(PCAPIRelay.activeConfig())
    }

    // MARK: - Health / sticky bypass

    func testGoesDirectAfterRepeatedFailures() {
        PCAPIRelay.configure(config)
        for _ in 0 ..< PCAPIRelay.failureThreshold {
            PCAPIRelay.recordFailure()
        }
        XCTAssertNil(PCAPIRelay.activeConfig(), "a dead relay should cost one attempt per window, not one per request")
        XCTAssertTrue(PCAPIRelay.isEnabled, "still switched on — just bypassed")
    }

    func testASuccessResetsTheFailureCount() {
        PCAPIRelay.configure(config)
        PCAPIRelay.recordFailure()
        PCAPIRelay.recordFailure()
        PCAPIRelay.recordSuccess()
        PCAPIRelay.recordFailure()
        XCTAssertNotNil(PCAPIRelay.activeConfig(), "intermittent failures must not trip the bypass")
    }

    func testReconfiguringClearsTheBypass() {
        // Changing server or token is the user telling us something changed; don't hold a grudge
        // from the previous configuration against it.
        PCAPIRelay.configure(config)
        for _ in 0 ..< PCAPIRelay.failureThreshold { PCAPIRelay.recordFailure() }
        XCTAssertNil(PCAPIRelay.activeConfig())

        PCAPIRelay.configure(PCAPIRelay.Config(baseURL: URL(string: "https://other.example.org")!, token: "t2"))
        XCTAssertNotNil(PCAPIRelay.activeConfig())
    }

    // MARK: - App-side gating

    func testRelayIsUnavailableWithoutAServerOrToken() {
        let url = Settings.sessionServerURL()
        let token = Settings.sessionServerToken()
        defer {
            Settings.setSessionServerURL(url?.absoluteString)
            Settings.setSessionServerToken(token)
        }

        Settings.setSessionServerURL(nil)
        Settings.setSessionServerToken(nil)
        XCTAssertFalse(Settings.sessionServerRelayAvailable())

        Settings.setSessionServerURL("https://pcs.example.org")
        XCTAssertFalse(Settings.sessionServerRelayAvailable(), "a URL alone cannot authenticate")

        Settings.setSessionServerToken("tok")
        XCTAssertTrue(Settings.sessionServerRelayAvailable())
    }

    func testApplyingSettingsWithoutATokenLeavesTheRelayOff() {
        let url = Settings.sessionServerURL()
        let token = Settings.sessionServerToken()
        let enabled = Settings.sessionServerRelayAPI()
        defer {
            Settings.setSessionServerURL(url?.absoluteString)
            Settings.setSessionServerToken(token)
            Settings.setSessionServerRelayAPI(enabled)
            PCAPIRelay.configure(nil)
        }

        Settings.setSessionServerRelayAPI(true)
        Settings.setSessionServerURL("https://pcs.example.org")
        Settings.setSessionServerToken(nil)
        PCAPIRelaySettings.apply()
        XCTAssertFalse(PCAPIRelay.isEnabled, "the toggle alone must not route traffic at a server we cannot authenticate to")
    }
}
