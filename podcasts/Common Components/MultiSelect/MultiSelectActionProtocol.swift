import Foundation
import PocketCastsDataModel

@MainActor
protocol MultiSelectActionDelegate: AnyObject, Sendable {
    func multiSelectPresentingViewController() -> UIViewController
    func multiSelectedBaseEpisodes() -> [BaseEpisode]
    func multiSelectedPlayListEpisodes() -> [PlaylistEpisode]?
    func multiSelectActionBegan(status: String)
    func multiSelectActionCompleted()
    /// Fork: the page's own session, so multi-select Add to Session prefers it (and
    /// may find-or-create it) exactly like the page's swipe does.
    func multiSelectPreferredSession() -> ForkSession?
    /// Fork: the page's EXISTING session, for Remove from Session — never creates.
    func multiSelectCurrentSession() -> ForkSession?
    var multiSelectViewSource: AnalyticsSource { get }
}

extension MultiSelectActionDelegate {
    func multiSelectPreferredSession() -> ForkSession? { nil }
    func multiSelectCurrentSession() -> ForkSession? { nil }
}
