import Foundation
import PocketCastsDataModel

class ListEpisode: ListItem {
    let episode: Episode
    let tintColor: UIColor

    // Fork: session membership captured at build time. The session mini-badge is painted in
    // cell config, so the DifferenceKit diff must see membership changes as content changes —
    // otherwise adding an episode to a session leaves the visible row's badge stale.
    let inAnySession: Bool

    init(episode: Episode, tintColor: UIColor) {
        self.episode = episode
        self.tintColor = tintColor
        #if !APPCLIP && !os(watchOS)
        self.inAnySession = SessionMembership.shared.inAnySession.contains(episode.uuid)
        #else
        self.inAnySession = false
        #endif

        super.init()
    }

    override var differenceIdentifier: String {
        episode.uuid
    }

    static func == (lhs: ListEpisode, rhs: ListEpisode) -> Bool {
        lhs.handleIsEqual(rhs)
    }

    // list episodes are considered equal only if the things that represent them in a list haven't changed
    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let rhs = otherItem as? ListEpisode else { return false }

        return episode.uuid == rhs.episode.uuid &&
            episode.episodeStatus == rhs.episode.episodeStatus &&
            episode.playingStatus == rhs.episode.playingStatus &&
            episode.playedUpTo == rhs.episode.playedUpTo &&
            episode.duration == rhs.episode.duration &&
            episode.archived == rhs.episode.archived &&
            episode.playbackErrorDetails == rhs.episode.playbackErrorDetails &&
            episode.keepEpisode == rhs.episode.keepEpisode &&
            episode.sizeInBytes == rhs.episode.sizeInBytes &&
            inAnySession == rhs.inAnySession &&
            tintColor == rhs.tintColor
    }
}

extension ListEpisode: Identifiable, Hashable {
    var id: String {
        episode.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
