import UIKit

/// Fork: the three states of the "in a session" mini-badge on an episode row.
///
/// Membership is per-session (sessions are independent), so the badge distinguishes whether an
/// episode is in *this* page's session or in some *other* session — same glyph, two brightnesses.
enum SessionIndicatorState {
    /// Not in any session — no badge.
    case none
    /// In the session this page represents — full-brightness green.
    case thisSession
    /// In a session, but not this page's — the same green at half brightness.
    case otherSession

    /// Resolves the state for an episode: in this page's session, else in any session, else none.
    /// `thisSession` is the page's own session store membership (empty on pages with no session).
    static func resolve(_ episodeUuid: String, thisSession: Set<String>) -> SessionIndicatorState {
        if thisSession.contains(episodeUuid) { return .thisSession }
        if SessionMembership.shared.inAnySession.contains(episodeUuid) { return .otherSession }
        return .none
    }

    var isVisible: Bool { self != .none }

    /// The badge tint, or nil when hidden. "Other session" is the session green at 50% brightness.
    var tint: UIColor? {
        switch self {
        case .none: return nil
        case .thisSession: return ThemeColor.support02()
        case .otherSession: return ThemeColor.support02().sessionDimmed()
        }
    }
}

extension UIColor {
    /// Halves the colour's brightness (HSB) — used for the "in another session" badge.
    func sessionDimmed(_ factor: CGFloat = 0.5) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: b * factor, alpha: a)
    }
}
