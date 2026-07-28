import Foundation
import PocketCastsDataModel

class PlaylistDetailFetchOperation: Operation, @unchecked Sendable {
    typealias CompletionHandler = ([ListEpisode], Int) -> Void

    private let episodesDataManager: EpisodesDataManager
    private let dataManager: DataManager
    private let playlist: EpisodeFilter
    private let completion: CompletionHandler

    init(
        dataManager: DataManager = .sharedManager,
        episodesDataManager: EpisodesDataManager = .init(),
        playlist: EpisodeFilter,
        completion: @escaping CompletionHandler
    ) {
        self.dataManager = dataManager
        self.episodesDataManager = episodesDataManager
        self.playlist = playlist
        self.completion = completion

        super.init()
    }

    override func main() {
        autoreleasepool {
            if self.isCancelled { return }

            // Fork: a session store's fetch IS the lineup, and the Session tab sieves it with the
            // SESSION-scope preset afterwards. Applying the Episodes-scope preset here would
            // double-filter the lineup with the wrong scope — switching the Session preset then
            // looks inert whenever the Episodes preset is narrowing.
            let preset = SessionStore.shared.session(forStore: playlist.uuid) == nil ? FilterPresets.active() : nil
            let newData = episodesDataManager.playlistEpisodes(for: playlist, preset: preset)

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
