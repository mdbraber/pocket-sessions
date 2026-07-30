import Foundation
import PocketCastsDataModel

/// Fork: "which of my playlists is this podcast in?" — the Playlists tab on a podcast page.
///
/// A podcast's episodes scatter across manual playlists, smart playlists and sessions, and until
/// now the only way to find out was to open each one. This answers it from the podcast's side.
struct PodcastPlaylistRow {
    /// What kind of list this is, which decides both the subtitle and the Show filter.
    ///
    /// A smart playlist that feeds a session exists TWICE — the playlist itself, and the session's
    /// store — so both can hold episodes of this podcast. They're separate rows because they are
    /// separate lists with separate contents; the ⋯ Show filter picks which of the pair to see.
    enum Kind {
        case manualPlaylist
        case smartPlaylist
        case smartPlaylistSession
        case podcastSession
        case folderSession

        var title: String {
            switch self {
            case .manualPlaylist: return L10n.podcastPlaylistsKindManual
            case .smartPlaylist: return L10n.podcastPlaylistsKindSmart
            case .smartPlaylistSession: return L10n.podcastPlaylistsKindSmartSession
            case .podcastSession: return L10n.podcastPlaylistsKindPodcastSession
            case .folderSession: return L10n.podcastPlaylistsKindFolderSession
            }
        }

        /// Sessions and plain playlists are the two halves the Show filter chooses between.
        var isSession: Bool {
            switch self {
            case .manualPlaylist, .smartPlaylist: return false
            case .smartPlaylistSession, .podcastSession, .folderSession: return true
            }
        }
    }

    let playlist: EpisodeFilter
    let kind: Kind
    /// How many episodes OF THIS PODCAST the list holds — not the list's total, which would say
    /// nothing about the podcast whose page you're on.
    let episodeCount: Int

    var uuid: String { playlist.uuid }
    var name: String { playlist.playlistName }
}

/// Fork: which of the two halves of a smart-playlist-plus-session pair to show.
enum PodcastPlaylistsShow: Int, CaseIterable {
    case both = 0
    case playlists = 1
    case sessions = 2

    var title: String {
        switch self {
        case .both: return L10n.podcastPlaylistsShowBoth
        case .playlists: return L10n.podcastPlaylistsShowPlaylists
        case .sessions: return L10n.podcastPlaylistsShowSessions
        }
    }

    private static let key = "SJPodcastPlaylistsShow"

    static var current: PodcastPlaylistsShow {
        get { PodcastPlaylistsShow(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .both }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum PodcastPlaylistRows {
    /// Every list holding at least one episode of `podcastUuid`, newest-interesting first.
    ///
    /// Deliberately excluded: deleted playlists, the hidden "— feed" machinery the Playlists tab
    /// also hides, the global Inbox, and THIS podcast's own session — you are already looking at
    /// that one, so listing it would just be the page pointing at itself.
    ///
    /// Hits the database once per list, so call it off the main thread.
    static func current(forPodcast podcastUuid: String, show: PodcastPlaylistsShow = .current) -> [PodcastPlaylistRow] {
        let ownSessionStore = SessionStore.shared.session(forPodcast: podcastUuid)?.storePlaylistUuid
        let feederUuids = SessionStore.shared.feederPlaylistUuids

        return DataManager.sharedManager.allPlaylists(includeDeleted: false).compactMap { playlist -> PodcastPlaylistRow? in
            guard playlist.uuid != ownSessionStore, !feederUuids.contains(playlist.uuid) else { return nil }
            guard let kind = kind(for: playlist) else { return nil }
            guard show == .both || kind.isSession == (show == .sessions) else { return nil }

            let count = episodeCount(of: podcastUuid, in: playlist)
            guard count > 0 else { return nil }

            return PodcastPlaylistRow(playlist: playlist, kind: kind, episodeCount: count)
        }
    }

    /// How many of `podcastUuid`'s episodes a list holds.
    ///
    /// A manual playlist's membership is a table, so one grouped query answers it. A smart
    /// playlist's is a rule, so it needs the query run with the podcast ANDed in — but only when
    /// the playlist's own podcast scope could match at all, which skips the query entirely for
    /// most lists.
    private static func episodeCount(of podcastUuid: String, in playlist: EpisodeFilter) -> Int {
        if playlist.manual {
            return DataManager.sharedManager.playlistEpisodeCountsByPodcast(for: playlist.uuid)[podcastUuid] ?? 0
        }
        guard smartPlaylistCouldCover(podcastUuid: podcastUuid, playlist: playlist) else { return 0 }
        return DataManager.sharedManager.playlistEpisodes(for: playlist, matching: "episode.podcastUuid = '\(podcastUuid)'").count
    }

    /// The cheap pre-filter: a smart playlist scoped to named podcasts can only match those.
    private static func smartPlaylistCouldCover(podcastUuid: String, playlist: EpisodeFilter) -> Bool {
        playlist.filterAllPodcasts
            || playlist.podcastUuids.components(separatedBy: ",").contains(podcastUuid)
    }

    /// nil for a list that shouldn't appear at all (the global Inbox's store).
    private static func kind(for playlist: EpisodeFilter) -> PodcastPlaylistRow.Kind? {
        guard let session = SessionStore.shared.session(forStore: playlist.uuid) else {
            return playlist.manual ? .manualPlaylist : .smartPlaylist
        }
        guard session.uuid != SessionStore.globalInboxUuid else { return nil }
        switch session.feeder {
        case .smartPlaylist: return .smartPlaylistSession
        case .podcast: return .podcastSession
        case .folder: return .folderSession
        // A hand-made session's store IS its identity — it behaves like a manual playlist.
        case .none: return .manualPlaylist
        case .allPodcasts: return nil
        }
    }
}
