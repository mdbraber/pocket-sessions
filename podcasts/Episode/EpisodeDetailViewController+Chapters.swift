import PocketCastsDataModel
import SwiftUI
import UIKit

extension EpisodeDetailViewController {
    /// Fork: shows this episode's chapters on the episode screen, above the show notes.
    ///
    /// Chapters used to be visible only while playing, because the only thing that ever loaded them
    /// was `ChapterManager`, which belongs to `PlaybackManager` and holds one episode at a time.
    /// `EpisodeChaptersLoader` lifts that restriction; this is the screen that uses it.
    ///
    /// Inserted next to the transcript excerpt rather than added to the XIB: both are optional
    /// sections that appear only when their data exists, and the excerpt is already an arranged
    /// subview of the stack, so a sibling gets the same layout behaviour for free.
    func loadChapters() {
        guard let stack = transcriptExcerpt?.superview as? UIStackView else { return }

        let episode = self.episode
        Task { [weak self] in
            let chapters = await EpisodeChaptersLoader.load(for: episode)
            guard !chapters.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.episode.uuid == episode.uuid else { return }
                self.showChapters(chapters, in: stack)
            }
        }
    }

    private func showChapters(_ chapters: [ChapterInfo], in stack: UIStackView) {
        // A second load (the screen can reload its data) must replace the list, not stack another.
        chaptersHostingController?.willMove(toParent: nil)
        chaptersHostingController?.view.removeFromSuperview()
        chaptersHostingController?.removeFromParent()

        let root = EpisodeChaptersView(chapters: chapters) { [weak self] chapter in
            self?.playFromChapter(chapter)
        }
        .environmentObject(Theme.sharedTheme)

        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        // Directly above the show notes: chapters describe the episode, so they belong with the
        // rest of its detail rather than below a long article.
        let index = transcriptExcerpt.map { stack.arrangedSubviews.firstIndex(of: $0).map { $0 + 1 } ?? stack.arrangedSubviews.count } ?? stack.arrangedSubviews.count
        stack.insertArrangedSubview(host.view, at: min(index, stack.arrangedSubviews.count))
        host.didMove(toParent: self)
        chaptersHostingController = host
    }

    /// Starts the episode at the tapped chapter.
    ///
    /// If this episode is already the one loaded, seek within it — reloading would restart buffering
    /// for no reason. Otherwise set the position first and start it through the screen's normal play
    /// path, which is what routes a session's episode into that session rather than the queue.
    private func playFromChapter(_ chapter: ChapterInfo) {
        let seconds = chapter.startTime.seconds
        Analytics.track(.playerChapterSelected, properties: [
            "origin": PlaybackManager.shared.chaptersOriginAnalyticsValue,
            // A new surface for this event: the episode screen, rather than the player.
            "source": "episode_detail",
            "episode_uuid": episode.uuid,
            "podcast_uuid": episode.parentIdentifier()
        ])

        if PlaybackManager.shared.isActivelyPlaying(episodeUuid: episode.uuid) || PlaybackManager.shared.currentEpisode()?.uuid == episode.uuid {
            PlaybackManager.shared.seekTo(time: seconds, startPlaybackAfterSeek: true)
            return
        }

        DataManager.sharedManager.saveEpisode(playedUpTo: seconds, episode: episode, updateSyncFlag: false)
        episode.playedUpTo = seconds
        updateProgress()
        playPauseEpisode(isPlaying: false)
    }
}
