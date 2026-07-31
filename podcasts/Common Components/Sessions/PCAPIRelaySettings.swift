import Foundation
import PocketCastsServer
import PocketCastsUtils

/// Fork: the one place that turns the app's settings into the transport's relay config.
///
/// `PCAPIRelay` lives in the server module and cannot read `Settings` (the module does not depend on
/// the app), so the app pushes the config in. Everything that can change the answer — the toggle,
/// the server URL, the device token — routes through `apply()`, and `PCAPIRelay` reads its config
/// per request, so a change takes effect on the next request without a restart.
enum PCAPIRelaySettings {
    /// Call once at launch, before any API request can be made.
    static func install() {
        PCAPIRelay.install()
        apply()
    }

    /// Recompute and hand over the current config. Relaying is only possible with all three of the
    /// toggle, a server URL and a device token; missing any of them means going direct, which is
    /// also exactly what happens when the user signs out or unlinks.
    static func apply() {
        guard Settings.sessionServerRelayAPI(),
              let baseURL = Settings.sessionServerURL(),
              let token = Settings.sessionServerToken() else {
            PCAPIRelay.configure(nil)
            return
        }
        PCAPIRelay.configure(PCAPIRelay.Config(baseURL: baseURL, token: token))
    }

    /// Flips the toggle and applies it in one step, so no caller can set one without the other.
    static func setEnabled(_ enabled: Bool) {
        Settings.setSessionServerRelayAPI(enabled)
        apply()
        FileLog.shared.addMessage("PCAPIRelay: user set relay \(enabled ? "on" : "off")")
    }
}
