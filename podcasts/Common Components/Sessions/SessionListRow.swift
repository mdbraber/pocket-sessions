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
    /// Fork: the pinned "Up Next" entry that heads the session list — the queue as a special
    /// always-first row. Not a real session; tapping it opens the queue world, not a lineup.
    var isUpNext: Bool = false
    /// Season/episode shorthand for the next episode (e.g. "S4 E2"), shown before its title. Nil
    /// when the episode carries no season/episode numbering.
    var nextEpisodeSeasonEpisode: String?
    /// Fork: this session is fed by a smart playlist — the row shows a sparkles glyph before the name.
    var isSmartPlaylist: Bool = false
    /// Fork: this lane OWNS the now-playing card right now (drives the active border + play/pause
    /// routing). Distinct from `isActive`: a session can hold the active pointer while parked behind
    /// the queue — then the queue owns the card, not the session.
    var ownsCard: Bool = false
}

/// Fork: how the session chooser orders its rows. Persisted (see `Settings.sessionListSort`);
/// the Switch Session sheet deliberately ignores it and always uses `.recentlyPlayed`.
enum SessionListSort: Int, CaseIterable {
    case recentlyPlayed
    case name
    case timeLeft
    case recentlyUpdated
    /// Fork: the user's own drag order (SessionStore array order) — the session list's default,
    /// making it a manually-arranged "recent/planned" list.
    case manual
    /// Fork: the episode-style sorts offered in the session list's ⋯ Sort menu.
    /// Newest/Oldest sort on the session's most-recently-published episode; Shortest/Longest on the
    /// session's FULL length (every episode's duration, not just what's left).
    case newestToOldest
    case oldestToNewest
    case shortestToLongest
    case longestToShortest
    /// Fork: most-progressed session first (the resume position of its next episode).
    case progress

    var title: String {
        switch self {
        case .recentlyPlayed: L10n.sessionSortRecent
        case .name: L10n.sessionSortName
        case .timeLeft: L10n.sessionSortTimeLeft
        case .recentlyUpdated: L10n.sessionSortUpdated
        case .manual: L10n.sessionSortManual
        case .newestToOldest: L10n.podcastsEpisodeSortNewestToOldest
        case .oldestToNewest: L10n.podcastsEpisodeSortOldestToNewest
        case .shortestToLongest: L10n.podcastsEpisodeSortShortestToLongest
        case .longestToShortest: L10n.podcastsEpisodeSortLongestToShortest
        case .progress: L10n.sessionSortProgress
        }
    }

    /// Fork: the options the session list's ⋯ Sort menu offers, in order — Manual (the drag order)
    /// plus the episode-style sorts (Serial deliberately excluded) and Progress.
    static let sessionMenuOrder: [SessionListSort] = [.manual, .newestToOldest, .oldestToNewest, .shortestToLongest, .longestToShortest, .progress]
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
        // Hoisted out of the per-session loop: the toggle (read once) and, only when it's on, the
        // covered-podcast set (computed once instead of an O(sessions) scan per podcast session).
        let hidePodcastsInSmart = Settings.hidePodcastSessionsInSmartPlaylist()
        let smartCoveredPodcasts = hidePodcastsInSmart ? SessionManager.shared.smartPlaylistCoveredPodcastUuids() : []
        // One stateless episode reader for the whole build (EpisodesDataManager has no shared instance).
        let episodeSource = EpisodesDataManager()

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
            // Fork: the session list no longer mirrors the Playlists tab's "Show Session Playlists"
            // selection — it's a manually-ordered "recent/planned" list of ALL your sessions, gated
            // only by the two ⋯ toggles: "Hide empty sessions" (below) and this one, "Hide Podcasts
            // in Smart Playlists" — a per-podcast session whose podcast a smart-playlist session
            // already covers is redundant, so drop it (the active session always stays reachable).
            if !isActive, hidePodcastsInSmart,
               case .podcast(let podcastUuid) = session.feeder,
               smartCoveredPodcasts.contains(podcastUuid) {
                return nil
            }
            // Exactly what playback reads: the store, in its own order. Uses the already-fetched
            // `store` filter so this doesn't re-run `findPlaylist(uuid:)` a second time per session.
            let ordered = episodeSource.playlistEpisodes(for: store).map { $0.episode }
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

            let isSmartPlaylist: Bool
            if case .smartPlaylist = session.feeder { isSmartPlaylist = true } else { isSmartPlaylist = false }

            let row = SessionListRow(
                sessionUuid: session.uuid,
                storeUuid: storeUuid,
                name: store.playlistName,
                nextEpisodePodcastUuid: (next as? Episode)?.podcastUuid,
                isPlaying: isActive && !sessionPaused && PlaybackManager.shared.currentEpisodeIsSessionSourced && PlaybackManager.shared.playing(),
                isActive: isActive,
                nextEpisodeTitle: next?.displayableTitle(),
                nextEpisodePodcast: next.flatMap { podcastName(for: $0) },
                nextEpisodeDuration: next.map { durationText(for: $0) },
                progress: next.map { progress(for: $0) } ?? 0,
                episodeCount: remaining.count,
                timeLeft: remaining.isEmpty ? nil : TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalRemaining),
                nextEpisodeSeasonEpisode: (next as? Episode).flatMap { seasonEpisodeShorthand(for: $0) },
                isSmartPlaylist: isSmartPlaylist,
                // Owns the card only when active, not parked, AND the current card is actually this
                // session's episode — otherwise a session holding the pointer while the queue plays
                // would wrongly read as owning the card (both lanes then look like they're playing).
                ownsCard: isActive && !sessionPaused && PlaybackManager.shared.currentEpisodeIsSessionSourced
            )
            return Entry(
                row: row,
                session: session,
                index: index,
                remainingSeconds: totalRemaining,
                // Full session length = every episode's duration (not just what's left) — the
                // Shortest/Longest sort key.
                fullLength: ordered.reduce(0.0) { $0 + $1.duration },
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
            // NOTE: `current()` is a PURE sorted builder — it no longer hoists the active session to
            // the top. The Queue surfaces the current session by extracting it into its own row-1
            // card (so hoisting here would double-handle it and reshuffle the pool on activation), and
            // the recency-ordered consumers (Switch Session sheet, CarPlay) already float the playing
            // session up via its `lastUsed` (bumped to now on playbackStarted). Any consumer that wants
            // the active session first should hoist it at its own layer.
            switch sort {
            case .manual:
                // The user's own drag order (synced `sortIndex`); never-placed sessions (Int.max)
                // fall to the end in creation order (the array index).
                if lhs.session.sortIndex != rhs.session.sortIndex {
                    return lhs.session.sortIndex < rhs.session.sortIndex
                }
                return lhs.index < rhs.index
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
            case .newestToOldest, .oldestToNewest:
                switch (lhs.newestPublished, rhs.newestPublished) {
                case (let left?, let right?):
                    if left != right { return sort == .newestToOldest ? left > right : left < right }
                case (.some, .none): return true   // a dated session sorts above an undated one
                case (.none, .some): return false
                case (.none, .none): break
                }
                return byName(lhs, rhs)
            case .shortestToLongest, .longestToShortest:
                if lhs.fullLength != rhs.fullLength {
                    return sort == .shortestToLongest ? lhs.fullLength < rhs.fullLength : lhs.fullLength > rhs.fullLength
                }
                return byName(lhs, rhs)
            case .progress:
                // Most progress first (the resume position of the session's next episode).
                if lhs.row.progress != rhs.row.progress { return lhs.row.progress > rhs.row.progress }
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
        let fullLength: Double
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

    /// "S4 E2" (or "S4") — only when SEASON info is present. Episode-only numbering shows nothing.
    private static func seasonEpisodeShorthand(for episode: Episode) -> String? {
        guard episode.seasonNumber > 0 else { return nil }
        let text = L10n.seasonEpisodeShorthand(seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
        return text.isEmpty ? nil : text
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
            // Fork: the session list defaults to the manual drag order.
            return .manual
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
    static let hidePodcastSessionsInSmartPlaylistKey = "SJHidePodcastSessionsInSmartPlaylist"

    /// Fork: the session list's "Hide Podcasts in Smart Playlists" toggle — drops a per-podcast
    /// session when that podcast is already covered by a smart-playlist session (redundant).
    class func hidePodcastSessionsInSmartPlaylist() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.hidePodcastSessionsInSmartPlaylistKey)
    }

    class func setHidePodcastSessionsInSmartPlaylist(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: Settings.hidePodcastSessionsInSmartPlaylistKey)
    }

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
