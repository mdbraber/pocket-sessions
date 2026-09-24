import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: loads one episode's chapters without involving playback.
///
/// `ChapterManager` — the app's usual route — belongs to `PlaybackManager` and only ever holds the
/// CURRENTLY PLAYING episode's chapters, which is why chapters have only ever been visible in the
/// player. Nothing about the underlying sources requires that: `ShowInfoCoordinator.loadChapters`
/// is already episode-scoped and playback-independent. This wraps it so any screen can ask.
///
/// **What it deliberately does not do.** Playback's loader also parses chapters embedded in the
/// media file, streaming the file's metadata when the episode isn't downloaded
/// (`PodcastChapterParser.parseRemoteFile`). That is far too expensive for a detail screen the user
/// is merely looking at, so embedded chapters are read only when the file is already local. The
/// consequence is worth knowing: for a not-yet-downloaded episode whose chapters live inside the
/// file, this returns the external ones (or none) while the player, once playing, may show the
/// embedded set instead.
enum EpisodeChaptersLoader {
    static func load(for episode: BaseEpisode, parser: PodcastChapterParser = PodcastChapterParser()) async -> [ChapterInfo] {
        // Same precedence as playback: a file's own chapters win, because for some shows they
        // account for dynamic ad insertion and the external list does not.
        if episode.downloaded(pathFinder: DownloadManager.shared) {
            let fileChapters = await parser.parseLocalFile(
                episode.pathToDownloadedFile(pathFinder: DownloadManager.shared),
                episodeDuration: episode.duration
            )
            if !fileChapters.isEmpty { return fileChapters }
        }

        guard let (podlove, podcastIndex, generated) = try? await ShowInfoCoordinator.shared.loadChapters(
            podcastUuid: episode.parentIdentifier(),
            episodeUuid: episode.uuid
        ) else { return [] }

        if let podcastIndex {
            return parser.parsePodcastIndexChapters(podcastIndex, episodeDuration: episode.duration)
        }
        if let podlove {
            return parser.parsePodloveChapters(podlove, episodeDuration: episode.duration)
        }
        if let generated {
            return parser.parseGeneratedChapters(generated, episodeDuration: episode.duration)
        }
        return []
    }
}
