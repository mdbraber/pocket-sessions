import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

extension UpNextViewController: MultiSelectActionDelegate {
    func multiSelectPresentingViewController() -> UIViewController {
        self
    }

    func multiSelectedBaseEpisodes() -> [BaseEpisode] {
        if FeatureFlag.playbackSessions.enabled, displayedWorld == .session {
            return selectedSessionEpisodes
        }
        return selectedPlayListEpisodes.compactMap { DataManager.sharedManager.findBaseEpisode(uuid: $0.episodeUuid) }
    }

    func multiSelectedPlayListEpisodes() -> [PlaylistEpisode]? {
        // Session rows aren't queue rows — queue-specific actions get nothing to act on.
        if FeatureFlag.playbackSessions.enabled, displayedWorld == .session {
            return nil
        }
        return selectedPlayListEpisodes
    }

    func multiSelectActionBegan(status: String) {
        multiSelectActionBar.setStatus(status: status)
    }

    func multiSelectActionCompleted() {
        isMultiSelectEnabled = false
    }

    var multiSelectViewSource: AnalyticsSource {
        analyticsSource
    }

    // MARK: - Long Press Multi Select Option Picker

    func showLongPressSelectOptions(indexPath: IndexPath) {
        longPressSelectOptions(
            for: indexPath,
            in: upNextTable,
            themeOverride: themeOverride
        )
    }

    // MARK: - Selected Episode

    func selectedEpisodesContains(uuid: String) -> Bool {
        if FeatureFlag.playbackSessions.enabled, displayedWorld == .session {
            return selectedSessionEpisodes.contains { $0.uuid == uuid }
        }
        let selectedUuids = selectedPlayListEpisodes.map(\.episodeUuid)
        return selectedUuids.contains(uuid)
    }

    func selectedEpisodesContainsUserEpisode() -> Bool {
        for episode in selectedPlayListEpisodes {
            if episode.isUserEpisode() {
                return true
            }
        }
        return false
    }

    func selectedEpisodesRemove(uuid: String) {
        if let index = selectedSessionEpisodes.firstIndex(where: { $0.uuid == uuid }) {
            selectedSessionEpisodes.remove(at: index)
        }
        let selectedUuids = selectedPlayListEpisodes.map(\.episodeUuid)
        if let currentEpisodeIndex = selectedUuids.firstIndex(of: uuid) {
            selectedPlayListEpisodes.remove(at: currentEpisodeIndex)
        }
    }
}
