import PocketCastsServer
import PocketCastsUtils

extension PlaylistDetailViewController {
    struct PlaylistReloadScope: OptionSet {
        let rawValue: Int

        static let episodes = PlaylistReloadScope(rawValue: 1 << 0)
        static let playlist = PlaylistReloadScope(rawValue: 1 << 1)
    }

    /// Fork: folder membership shows in the header's folder icon — re-render it.
    @objc private func filtersWereReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.viewModel.isSearching { self.viewModel.clearSearch() }
            self.viewModel.reloadEpisodeList(animated: false)
        }
    }

    @objc private func playlistFoldersChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.objectWillChange.send()
        }
    }

    func addObservers() {
        addCustomObserver(ServerNotifications.podcastsRefreshed, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.opmlImportCompleted, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.playbackTrackChanged, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.playbackFailed, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.playlistChanged, selector: #selector(refreshFilterFromNotification))
        addCustomObserver(PlaylistFolderManager.foldersChanged, selector: #selector(playlistFoldersChanged))
        addCustomObserver(Constants.Notifications.episodePlayStatusChanged, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.episodeArchiveStatusChanged, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.episodeStarredChanged, selector: #selector(refreshEpisodesFromNotification))
        addCustomObserver(Constants.Notifications.manyEpisodesChanged, selector: #selector(refreshEpisodesFromNotification))
        // Fork: seen marks and dismissals live in the session store — without this,
        // a mark-as-seen never refreshes the Inbox tab.
        addCustomObserver(SessionStore.changed, selector: #selector(refreshEpisodesFromNotification))
        // Fork: the active Filter Preset drives both tabs; repaint the funnel label and re-fetch
        // when it changes, and clear the search term on "Reset all filters".
        addCustomObserver(FilterPresetStore.changed, selector: #selector(presetStoreChanged))
        addCustomObserver(FilterPresets.resetAll, selector: #selector(filtersWereReset))
        addCustomObserver(UIResponder.keyboardWillShowNotification, selector: #selector(keyboardWillShow(_:)))
        addCustomObserver(UIResponder.keyboardWillHideNotification, selector: #selector(keyboardWillHide(_:)))
        // The pill appears/disappears without changing the table's bounds — force a layout pass so
        // the bottom clearance recomputes and the last row clears the pill.
        addCustomObserver(Constants.Notifications.miniPlayerDidAppear, selector: #selector(miniPlayerVisibilityChanged))
        addCustomObserver(Constants.Notifications.miniPlayerDidDisappear, selector: #selector(miniPlayerVisibilityChanged))
    }

    @objc private func miniPlayerVisibilityChanged() {
        view.setNeedsLayout()
    }

    @objc func keyboardWillShow(_ notification: Notification) {
        adjustTextViewForKeyboard(notification: notification, show: true)
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        adjustTextViewForKeyboard(notification: notification, show: false)
    }

    private func adjustTextViewForKeyboard(notification: Notification, show: Bool) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        let keyboardHeight = keyboardFrame.height
        keyBoardHeight = (show ? keyboardHeight - (view.distanceFromBottom() ?? 0) : 0)
    }
}
