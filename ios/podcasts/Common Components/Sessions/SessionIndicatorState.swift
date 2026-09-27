import UIKit

/// Fork: the three states of the "in a session" mini-badge on an episode row.
///
/// Membership is per-session (sessions are independent). The badge looks the same either way —
/// a filled green stack — and only VoiceOver says whether it is *this* page's session or another.
enum SessionIndicatorState {
    /// Not in any session — no badge.
    case none
    /// In the session this page represents.
    case thisSession
    /// In a session, but not this page's.
    case otherSession

    /// Resolves the state for an episode: in this page's session, else in any session, else none.
    /// `thisSession` is the page's own session store membership (empty on pages with no session).
    static func resolve(_ episodeUuid: String, thisSession: Set<String>) -> SessionIndicatorState {
        if thisSession.contains(episodeUuid) { return .thisSession }
        if SessionMembership.shared.inAnySession.contains(episodeUuid) { return .otherSession }
        return .none
    }

    var isVisible: Bool { self != .none }

    /// The badge tint, or nil when hidden.
    var tint: UIColor? {
        isVisible ? ThemeColor.support02() : nil
    }

    /// The badge glyph at the mini-indicator's standard size, or nil when hidden.
    var indicatorImage: UIImage? {
        guard isVisible else { return nil }
        return UIImage(systemName: "rectangle.stack.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    }

    /// VoiceOver description of the badge, or nil when hidden.
    var accessibilityLabel: String? {
        switch self {
        case .none: return nil
        case .thisSession: return L10n.accessibilityInThisLineup
        case .otherSession: return L10n.accessibilityInOtherLineup
        }
    }
}
