import Foundation
import PocketCastsDataModel

class PlaylistDetailFetchOperation: Operation, @unchecked Sendable {
    typealias CompletionHandler = ([ListEpisode], Int) -> Void

    private let episodesDataManager: EpisodesDataManager
    private let dataManager: DataManager
    private let playlist: EpisodeFilter
    private let preset: FilterPreset?
    private let thisSessionStoreUuid: String?
    private let completion: CompletionHandler

    /// `preset` is the page's to choose (see `PlaylistDetailViewModel.fetchPreset`): nil on a session
    /// store, whose fetch IS the lineup. `thisSessionStoreUuid` is the page's own session, for a
    /// contextual preset to resolve against.
    init(
        dataManager: DataManager = .shared,
        episodesDataManager: EpisodesDataManager = .init(),
        playlist: EpisodeFilter,
        preset: FilterPreset?,
        thisSessionStoreUuid: String?,
        completion: @escaping CompletionHandler
    ) {
        self.dataManager = dataManager
        self.episodesDataManager = episodesDataManager
        self.playlist = playlist
        self.preset = preset
        self.thisSessionStoreUuid = thisSessionStoreUuid
        self.completion = completion

        super.init()
    }

    override func main() {
        autoreleasepool {
            if self.isCancelled { return }

            let newData = episodesDataManager.playlistEpisodes(for: playlist, preset: preset, thisSessionStoreUuid: thisSessionStoreUuid)

            let archivedEpisodesCount = dataManager.playlistArchivedEpisodeCount(
                for: playlist,
                episodeUuidToAdd: playlist.episodeUuidToAddToQueries()
            )

            if self.isCancelled { return }

            DispatchQueue.main.sync { [weak self] in
                guard let strongSelf = self else { return }
                if strongSelf.isCancelled { return }

                strongSelf.completion(newData, archivedEpisodesCount)
            }
        }
    }
}
