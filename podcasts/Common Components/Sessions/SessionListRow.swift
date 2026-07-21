import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: one row of the session CHOOSER — the first level of the Up Next tab's Session
/// side. A row describes a session by the episode it would play next, so picking a row
/// and pressing play can never surprise the user.
struct SessionListRow: Equatable {
    let sessionUuid: String
    /// The manual playlist holding the lineup. Nil when the session has no store playlist.
    let storeUuid: String?
    let name: String
    /// Podcast uuid of the next episode — the row shows that episode's art, exactly like an
    /// Up Next row, so the row and what it promises to play are the same thing. Nil when the
    /// lineup is empty (there is no next episode to picture).
    let nextEpisodePodcastUuid: String?
    /// This session owns playback right now — active AND not paused.
    /// Audio is actually sounding for this session — entering a session primes it without
    /// playing, and a primed-but-silent session must not claim to be playing.
    let isPlaying: Bool
    /// This session owns the playback pointer, sounding or not. Pins it to the top and
    /// exempts it from filters, so the chooser can always get back to it.
    let isActive: Bool
    /// Nil when the lineup has nothing left to play.
    let nextEpisodeTitle: String?
    let nextEpisodePodcast: String?
    /// "58 min" when untouched; "22 min left" when part-played.
    let nextEpisodeDuration: String?
    /// playedUpTo / duration of the next episode, clamped 0...1. 0 when untouched or unknown.
    let progress: Double
    /// How many episodes are still to play in the lineup.
    let episodeCount: Int
    /// Remaining time across the whole lineup; nil when there is nothing left.
    let timeLeft: String?
}

/// Fork: how the session chooser orders its rows. Persisted (see `Settings.sessionListSort`);
/// the Switch Session sheet deliberately ignores it and always uses `.recentlyPlayed`.
enum SessionListSort: Int, CaseIterable {
    case recentlyPlayed
    case name
    case timeLeft
    case recentlyUpdated

    var title: String {
        switch self {
        case .recentlyPlayed: L10n.sessionSortRecent
        case .name: L10n.sessionSortName
        case .timeLeft: L10n.sessionSortTimeLeft
        case .recentlyUpdated: L10n.sessionSortUpdated
        }
    }
}

/// Fork: which sessions the chooser shows. Every `SessionFeeder` case maps to exactly one
/// bucket, so the three type toggles between them cover the whole enum:
/// `.podcast` → podcasts, `.folder` → folders, `.smartPlaylist` and `.none` → playlists
/// (a `.none` session is hand-made — it behaves like a manual playlist, which is where a
/// user would look for it), `.allPodcasts` → podcasts (only the global Inbox uses it, and
/// that never reaches the chooser).
enum SessionListTypeBucket {
    case podcast
    case playlist
    case folder

    init(feeder: SessionFeeder) {
        switch feeder {
        case .podcast, .allPodcasts: self = .podcast
        case .folder: self = .folder
        case .smartPlaylist, .none: self = .playlist
        }
    }
}

/// Fork: the chooser's "Show" toggles, as one value so the provider takes a single argument.
struct SessionListFilters {
    var hideEmpty: Bool
    /// Hides sessions never started — no progress and never played.
    var hideUnplayed: Bool
    var showPodcasts: Bool
    var showPlaylists: Bool
    var showFolders: Bool

    /// Shows everything — what the Switch Session sheet uses.
    static let unfiltered = SessionListFilters(hideEmpty: false, hideUnplayed: false, showPodcasts: true, showPlaylists: true, showFolders: true)

    /// What the user picked in the chooser's ⋯ menu.
    static var current: SessionListFilters {
        SessionListFilters(
            hideEmpty: Settings.sessionListHideEmpty(),
            hideUnplayed: Settings.sessionListHideUnplayed(),
            showPodcasts: Settings.sessionListShowPodcasts(),
            showPlaylists: Settings.sessionListShowPlaylists(),
            showFolders: Settings.sessionListShowFolders()
        )
    }

    var isDefault: Bool {
        !hideEmpty && !hideUnplayed && showPodcasts && showPlaylists && showFolders
    }

    func allows(episodeCount: Int, feeder: SessionFeeder, hasBeenPlayed: Bool) -> Bool {
        if hideEmpty, episodeCount == 0 { return false }
        if hideUnplayed, !hasBeenPlayed { return false }
        switch SessionListTypeBucket(feeder: feeder) {
        case .podcast: return showPodcasts
        case .playlist: return showPlaylists
        case .folder: return showFolders
        }
    }
}

/// Fork: builds the chooser's rows. Pure read — nothing here mutates a lineup.
enum SessionListRows {
    /// Every session the chooser should offer, ordered playing-first / most recently used.
    ///
    /// Visibility: the global Inbox is excluded (it has no store and isn't a lineup you
    /// play), as is any session whose store playlist is missing/deleted, and any session
    /// whose store is one of `SessionStore.feederPlaylistUuids` (the hidden "— feed"
    /// machinery the Playlists tab also filters out). The "Session Playlists" selection
    /// (`SessionManager.sessionStoreVisible`) IS applied — the chooser's ⋯ opens that same
    /// sheet, so it's one setting governing both surfaces — except that the active session
    /// stays reachable even when deselected, so playback is never stranded.
    ///
    /// `sort` and `filters` default to the user's chooser preferences, which is what the
    /// Up Next tab wants; the Switch Session sheet passes `.recentlyPlayed` / `.unfiltered`
    /// explicitly so the fast path stays a complete, recency-ordered list.
    static func current(sort: SessionListSort? = nil, filters: SessionListFilters? = nil) -> [SessionListRow] {
        let sort = sort ?? Settings.sessionListSort()
        let filters = filters ?? .current
        let activeUuid = Settings.playbackSession()?.uuid
        let sessionPaused = Settings.playbackSessionPaused()
        let resumeUuid = Settings.playbackSessionLastEpisodeUuid()
        let hideEmpty = Settings.hideEmptySessions()
        let feederUuids = SessionStore.shared.feederPlaylistUuids

        let sessions = SessionStore.shared.sessions
        let built: [Entry] = sessions.enumerated().compactMap { index, session in
            // A smart playlist can declare itself "not a session playlist" — its session (if one
            // was ever made) keeps its lineup, but it stops being offered anywhere. This provider
            // backs the chooser, the Switch Session sheet AND CarPlay, so the one filter covers all.
            if SessionManager.isOptedOut(feeder: session.feeder) { return nil }
            guard session.uuid != SessionStore.globalInboxUuid,
                  let storeUuid = session.storePlaylistUuid,
                  !feederUuids.contains(storeUuid),
                  let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid)
            else { return nil }

            let isActive = activeUuid == storeUuid
            // Fork: honour the "Show Session Playlists" selection here too — the chooser's ⋯ opens
            // that same sheet, so a deselected session must not appear here. The ACTIVE session is
            // always kept reachable (you're playing it) even if its store is deselected.
            if !isActive, !SessionManager.shared.sessionStoreVisible(playlistUuid: storeUuid) { return nil }
            // Exactly what playback reads: the store, in its own order.
            let ordered = PlaybackSession(type: .playlist, uuid: storeUuid).orderedEpisodes()
            // Episodes only leave a session when they finish — the same rule
            // `PlaybackSession.remainingEpisodes` uses.
            let remaining = ordered.filter { !$0.played() }

            // Fork: "Hide empty sessions" — nothing left to play. The active session stays put.
            if !isActive, hideEmpty, remaining.isEmpty { return nil }

            // The next episode is what playback would pick: the first unfinished episode,
            // except that the ACTIVE session resumes at its last-played episode while that
            // one is still in the lineup and unfinished (mirrors the paused-session resume
            // row in UpNextViewController+Table).
            var next = remaining.first
            if isActive, let resumeUuid, let resume = remaining.first(where: { $0.uuid == resumeUuid }) {
                next = resume
            }

            let totalRemaining = remaining.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) }

            let row = SessionListRow(
                sessionUuid: session.uuid,
                storeUuid: storeUuid,
                name: store.playlistName,
                nextEpisodePodcastUuid: (next as? Episode)?.podcastUuid,
                isPlaying: isActive && !sessionPaused && PlaybackManager.shared.playing(),
                isActive: isActive,
                nextEpisodeTitle: next?.displayableTitle(),
                nextEpisodePodcast: next.flatMap { podcastName(for: $0) },
                nextEpisodeDuration: next.map { durationText(for: $0) },
                progress: next.map { progress(for: $0) } ?? 0,
                episodeCount: remaining.count,
                timeLeft: remaining.isEmpty ? nil : TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalRemaining)
            )
            return Entry(
                row: row,
                session: session,
                index: index,
                remainingSeconds: totalRemaining,
                // `.recentlyUpdated` signal: the newest publish date in the lineup. The store
                // (PlaylistEpisode) records no added-at date, and the feeder engine keeps no
                // per-session timestamp, so there is no cheaper store-side signal — and this
                // one costs nothing extra, since `ordered` is already in hand for the row.
                // "Gained an episode" and "gained a newly published episode" coincide for
                // every feeder-fed session, which is all but hand-made ones.
                newestPublished: ordered.compactMap(\.publishedDate).max()
            )
        }

        // Filters run on built rows (the episode count is only known once the lineup is
        // read) but before sorting, so sorting never has to reason about hidden rows.
        let visible = built.filter { entry in
            // The playing session is never filtered out: a chooser that hides what is
            // currently sounding can't be used to get back to it.
            // Played means the user got into it: a part-played episode, or a recorded listen.
            entry.row.isActive || filters.allows(
                episodeCount: entry.row.episodeCount,
                feeder: entry.session.feeder,
                hasBeenPlayed: entry.row.progress > 0 || entry.session.lastUsed != nil
            )
        }

        return visible.sorted { lhs, rhs in
            // Only a SOUNDING session leads. Opening a session is navigation, not listening,
            // so merely stepping into one must not reshuffle the list you stepped out of.
            // A session paused mid-episode still rises via the progress tier below.
            if lhs.row.isPlaying != rhs.row.isPlaying { return lhs.row.isPlaying }

            switch sort {
            case .recentlyPlayed:
                return byRecency(lhs, rhs)
            case .name:
                return byName(lhs, rhs)
            case .timeLeft:
                // Empty sessions have no time left to compare, so they sink to the bottom.
                if (lhs.row.episodeCount == 0) != (rhs.row.episodeCount == 0) {
                    return rhs.row.episodeCount == 0
                }
                if lhs.row.episodeCount == 0 { return byName(lhs, rhs) }
                if lhs.remainingSeconds != rhs.remainingSeconds { return lhs.remainingSeconds < rhs.remainingSeconds }
                return byName(lhs, rhs)
            case .recentlyUpdated:
                switch (lhs.newestPublished, rhs.newestPublished) {
                case (let left?, let right?):
                    if left != right { return left > right }
                case (.some, .none):
                    // A session with something to date sorts above one with nothing at all.
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
                return byName(lhs, rhs)
            }
        }.map(\.row)
    }

    /// How many sessions the chooser would list with no filters applied. Used only to
    /// decide whether the sort/filter controls are worth showing, so it applies the same
    /// visibility guards as `current()` but skips reading any lineup.
    static func unfilteredCount() -> Int {
        // Counts the RAW set (only the permanent structural guards — inbox, hidden feeder store,
        // missing store, per-playlist opt-out). The reversible sheet selections (sessionStoreVisible,
        // hide-empty) are NOT applied: this decides whether the ⋯ control shows, and that control is
        // exactly what re-opens the sheet — so a full deselection must never remove it.
        let feederUuids = SessionStore.shared.feederPlaylistUuids
        return SessionStore.shared.sessions.filter { session in
            session.uuid != SessionStore.globalInboxUuid
                && !SessionManager.isOptedOut(feeder: session.feeder)
                && session.storePlaylistUuid.map { !feederUuids.contains($0) && DataManager.sharedManager.findPlaylist(uuid: $0) != nil } == true
        }.count
    }

    /// One session, plus the keys the sorts need but the row doesn't carry.
    private struct Entry {
        let row: SessionListRow
        let session: Session
        let index: Int
        let remainingSeconds: Double
        let newestPublished: Date?
    }

    /// Most recently used first; never-played sessions last, newest created first.
    private static func byRecency(_ lhs: Entry, _ rhs: Entry) -> Bool {
        // A part-played episode IS recency: you were in this session recently enough to be
        // mid-episode, whatever the stored timestamp says (it can be missing entirely when
        // the progress arrived by sync). So started sessions tier above untouched ones.
        if (lhs.row.progress > 0) != (rhs.row.progress > 0) { return lhs.row.progress > 0 }

        switch (lhs.session.lastUsed, rhs.session.lastUsed) {
        case (let left?, let right?):
            if left != right { return left > right }
        case (.some, .none):
            // Played sessions sort above never-played ones.
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            // Never played: newest created first. SessionStore appends on create, so a
            // higher index is the newer session.
            return lhs.index > rhs.index
        }
        return lhs.index > rhs.index
    }

    /// Case- and diacritic-insensitive localized compare, with the store order as a stable
    /// tie-break so identically-named sessions don't shuffle between reloads.
    private static func byName(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch lhs.row.name.compare(rhs.row.name, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.index < rhs.index
        }
    }

    // MARK: - Pieces

    /// "58 min" for an untouched episode, "22 min left" once it's part-played — the same
    /// formatter and string shape the Up Next header uses.
    private static func durationText(for episode: BaseEpisode) -> String {
        if episode.playedUpTo > 0 {
            let left = max(0, episode.duration - episode.playedUpTo)
            return L10n.queueUpNextHeaderTimeLeft(TimeFormatter.shared.multipleUnitFormattedShortTime(time: left))
        }
        return TimeFormatter.shared.multipleUnitFormattedShortTime(time: episode.duration)
    }

    private static func progress(for episode: BaseEpisode) -> Double {
        guard episode.duration > 0, episode.playedUpTo > 0 else { return 0 }
        return min(1, max(0, episode.playedUpTo / episode.duration))
    }

    private static func podcastName(for episode: BaseEpisode) -> String? {
        let title = episode.subTitle()
        return title.isEmpty ? nil : title
    }
}


/// Fork: the chooser's persisted view preferences live here, not in Settings.swift — that file
/// is compiled into the watch and widget targets too, which never see these app-only types.
extension Settings {

    static let sessionListSortKey = "SJSessionListSort"

    /// How the Up Next tab's session chooser orders its rows. View preference only — it
    /// never reaches the Switch Session sheet, which is always recency-ordered.
    class func sessionListSort() -> SessionListSort {
        guard let raw = UserDefaults.standard.object(forKey: Settings.sessionListSortKey) as? Int,
              let sort = SessionListSort(rawValue: raw)
        else {
            return .recentlyPlayed
        }
        return sort
    }

    class func setSessionListSort(_ sort: SessionListSort) {
        UserDefaults.standard.set(sort.rawValue, forKey: Settings.sessionListSortKey)
    }

    static let sessionListHideEmptyKey = "SJSessionListHideEmpty"
    static let sessionListHideUnplayedKey = "SJSessionListHideUnplayed"
    static let sessionListShowPodcastsKey = "SJSessionListShowPodcasts"
    static let sessionListShowPlaylistsKey = "SJSessionListShowPlaylists"
    static let sessionListShowFoldersKey = "SJSessionListShowFolders"

    /// The chooser's "Show" toggles. The three type toggles default to on (show
    /// everything); hiding empty sessions is opt-in.
    class func sessionListHideEmpty() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.sessionListHideEmptyKey)
    }

    class func setSessionListHideEmpty(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: Settings.sessionListHideEmptyKey)
    }

    class func sessionListHideUnplayed() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.sessionListHideUnplayedKey)
    }

    class func setSessionListHideUnplayed(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: Settings.sessionListHideUnplayedKey)
    }

    class func sessionListShowPodcasts() -> Bool {
        boolDefaultingToTrue(Settings.sessionListShowPodcastsKey)
    }

    class func setSessionListShowPodcasts(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Settings.sessionListShowPodcastsKey)
    }

    class func sessionListShowPlaylists() -> Bool {
        boolDefaultingToTrue(Settings.sessionListShowPlaylistsKey)
    }

    class func setSessionListShowPlaylists(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Settings.sessionListShowPlaylistsKey)
    }

    class func sessionListShowFolders() -> Bool {
        boolDefaultingToTrue(Settings.sessionListShowFoldersKey)
    }

    class func setSessionListShowFolders(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Settings.sessionListShowFoldersKey)
    }

    /// `UserDefaults.bool(forKey:)` reads a missing key as false, which is the wrong
    /// default for a "show this type" toggle.
    private class func boolDefaultingToTrue(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
