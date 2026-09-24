import DifferenceKit
import Foundation
import PocketCastsDataModel

class PodcastEpisodesRefreshOperation: Operation, @unchecked Sendable {
    private let episodesDataManager: EpisodesDataManager
    private let podcast: Podcast
    private let uuidsToFilter: [String]?
    private let completion: (([ArraySection<String, ListItem>]) -> Void)?

    init(episodesDataManager: EpisodesDataManager = EpisodesDataManager(), podcast: Podcast, uuidsToFilter: [String]?, completion: (([ArraySection<String, ListItem>]) -> Void)?) {
        self.episodesDataManager = episodesDataManager
        self.podcast = podcast
        self.uuidsToFilter = uuidsToFilter
        self.completion = completion

        super.init()
    }

    override func main() {
        autoreleasepool {
            if self.isCancelled { return }

            let newData = episodesDataManager.episodes(for: podcast, uuidsToFilter: uuidsToFilter)

            if self.isCancelled { return }
            DispatchQueue.main.sync { [weak self] in
                guard let strongSelf = self else { return }

                if strongSelf.isCancelled { return }

                strongSelf.completion?(newData)
            }
        }
    }

    /// Deliberately WITHOUT the active Filter Preset. This is CarPlay's query, and a preset chosen
    /// on the phone must not silently narrow a list you cannot see the control for.
    func createEpisodesQuery() -> String {
        episodesDataManager.createEpisodesQuery(podcast, uuidsToFilter: uuidsToFilter).query
    }
}
