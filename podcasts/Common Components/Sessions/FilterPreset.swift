import Foundation
import PocketCastsDataModel

/// A rule with three meanings needs three states, not four.
///
/// `Bool?` is the whole model for a binary axis: **nil = don't care**, true = must be, false = must
/// not be. The tempting alternative — a pair of bools (`starred` + `notStarred`) with "all-on or
/// all-off means unconstrained" — has *four* states for *three* meanings, so "any" ends up with two
/// different encodings. Two encodings of the same fact is precisely how things drift apart.
typealias Rule = Bool?

enum PlayingStatusRule: String, Codable, CaseIterable {
    case unplayed, inProgress, played
}

enum DownloadStatusRule: String, Codable, CaseIterable {
    case downloaded, downloading, notDownloaded
}

enum MediaTypeRule: String, Codable {
    case audio, video
}

/// Fork: a Filter Preset — a named set of rules for what an episode list shows.
///
/// **It is fork-owned, and that is the whole point.** It is not an `EpisodeFilter`, not a Smart
/// Playlist, and not a wrapper around one. Two of its rules — `unseen` and `inSession` — could
/// never have lived in `EpisodeFilter`: one resolves against a fork-owned playlist, the other
/// against fork-owned sessions. And `createSyncUserPlaylist` sends a fixed 22-field set with no
/// `seen` and no `archived` in it, so a rule stored on an `EpisodeFilter` is simply never
/// transmitted. A preset stored that way would mean *different things on different devices* —
/// "Long Reads (unseen only)" would silently become just "Long Reads" on the iPad. That is the
/// exact antipattern this fork's own post-mortem blamed for its fragility: never local meaning
/// riding on synced records.
///
/// Owning the model dissolves the old "lens vs rule" distinction, which turned out to be an
/// artefact of Pocket Casts' schema rather than anything real. Seen, archived and session
/// membership are just ordinary rules here.
///
/// ## Rule semantics
///
/// - **Binary axes are `Rule` (`Bool?`)**: nil = any, true = must, false = must not.
/// - **Multi-value axes are `Set`s** (playing status, download status), because "unplayed OR
///   in-progress" is a real thing to want and a tri-state cannot say it. An **empty set means any**
///   — and so does a full one, which the query builder tolerates so the editor's "all switches on"
///   behaves as expected.
/// - **Across axes, AND. Within a set, OR.**
///
/// Note how far this is from `EpisodeFilter`, which has three different shapes for the same idea:
/// `filterStarred` is a lone bool (it can say "starred only" but *not* "not starred"),
/// `filterAudioVideoType` is a 3-state enum, and archived is a scope flag. Those are artefacts of a
/// schema we do not control.
struct FilterPreset: Codable, Equatable, Identifiable {
    let uuid: String
    var name: String
    var iconId: Int
    /// Disabled presets are hidden from the quick picker (keeping it compact) but stay in the
    /// management list. Built-ins are seeds, so they can be disabled like any other.
    var enabled: Bool

    /// Empty (or full) = any. Otherwise the statuses are ORed.
    var playingStatus: Set<PlayingStatusRule>
    /// Empty (or full) = any. Otherwise the statuses are ORed.
    var downloadStatus: Set<DownloadStatusRule>

    var starred: Rule
    /// nil = any. Audio and video are the only two kinds, so this is a choice, not a set.
    var mediaType: MediaTypeRule?

    /// nil = any (**the default** — "All Episodes" includes archived), false = hide archived,
    /// true = archived only.
    ///
    /// As a rule rather than a scope flag, "archived only" is sayable — which the stock
    /// `showArchivedEpisodes` bool could not do.
    var archived: Rule

    /// Against the Inbox playlist. nil = any, true = unseen only, false = seen only.
    var unseen: Rule

    /// Against the union of ALL session store playlists. Deliberately a GLOBAL bit, not a
    /// page-relative one: an episode in the podcast's session also reads as "in session" from a
    /// smart-playlist page. That is what lets a preset know nothing about the page it renders on,
    /// which is what makes it portable.
    var inSession: Rule

    /// Scope: which podcasts the preset speaks for. Empty = all. `folderUuids` resolves to its
    /// member podcasts at query time. This is the ONE axis that is inherently about *which page you
    /// are on* rather than a property of an episode — so a single-podcast page (a podcast's own
    /// Episodes/Session list) deliberately ignores it, since scoping a one-podcast list is either a
    /// no-op or a silent empty. Everywhere with more than one podcast in play, it applies.
    var podcastUuids: Set<String>
    var folderUuids: Set<String>

    // Ranges. Genuinely not membership, so genuinely not rules.
    var filterDuration: Bool
    var longerThan: Int32 // minutes
    var shorterThan: Int32 // minutes
    /// Release window, in hours. 0 = any.
    var filterHours: Int32

    /// Applied to the list when the preset is selected, then overridable by the list's own sort
    /// control. nil = "none" (leave the list's current sort). Raw value of `TriageTabSortOrder`.
    var sortOrder: Int?
    /// Group By, applied on selection and overridable. Raw value of `EpisodeGroupBy` (0 = none).
    var groupBy: Int

    var id: String { uuid }

    init(
        uuid: String = UUID().uuidString,
        name: String,
        iconId: Int = 0,
        enabled: Bool = true,
        playingStatus: Set<PlayingStatusRule> = [],
        downloadStatus: Set<DownloadStatusRule> = [],
        starred: Rule = nil,
        mediaType: MediaTypeRule? = nil,
        archived: Rule = nil,
        unseen: Rule = nil,
        inSession: Rule = nil,
        podcastUuids: Set<String> = [],
        folderUuids: Set<String> = [],
        filterDuration: Bool = false,
        longerThan: Int32 = 0,
        shorterThan: Int32 = 0,
        filterHours: Int32 = 0,
        sortOrder: Int? = nil,
        groupBy: Int = 0
    ) {
        self.uuid = uuid
        self.name = name
        self.iconId = iconId
        self.enabled = enabled
        self.playingStatus = playingStatus
        self.downloadStatus = downloadStatus
        self.starred = starred
        self.mediaType = mediaType
        self.archived = archived
        self.unseen = unseen
        self.inSession = inSession
        self.podcastUuids = podcastUuids
        self.folderUuids = folderUuids
        self.filterDuration = filterDuration
        self.longerThan = longerThan
        self.shorterThan = shorterThan
        self.filterHours = filterHours
        self.sortOrder = sortOrder
        self.groupBy = groupBy
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, iconId, enabled, playingStatus, downloadStatus, starred, mediaType
        case archived, unseen, inSession, podcastUuids, folderUuids
        case filterDuration, longerThan, shorterThan, filterHours, sortOrder, groupBy
    }

    // CRITICAL: every key via decodeIfPresent. Synthesized Decodable throws keyNotFound on a
    // missing key even when the property has a default — see SessionStoreDecodeTests for the wipe
    // that caused.
    //
    // Note the optionals decode to nil rather than to the *creation* default. That is deliberate:
    // the decoder reproduces what was written (a `nil` rule round-trips as an absent key), while
    // the memberwise init above supplies the defaults for a NEW preset. A rule an older build never
    // wrote therefore reads as "any", which is the safe, non-narrowing answer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconId = try c.decodeIfPresent(Int.self, forKey: .iconId) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        playingStatus = try c.decodeIfPresent(Set<PlayingStatusRule>.self, forKey: .playingStatus) ?? []
        downloadStatus = try c.decodeIfPresent(Set<DownloadStatusRule>.self, forKey: .downloadStatus) ?? []
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred)
        mediaType = try c.decodeIfPresent(MediaTypeRule.self, forKey: .mediaType)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        unseen = try c.decodeIfPresent(Bool.self, forKey: .unseen)
        inSession = try c.decodeIfPresent(Bool.self, forKey: .inSession)
        podcastUuids = try c.decodeIfPresent(Set<String>.self, forKey: .podcastUuids) ?? []
        folderUuids = try c.decodeIfPresent(Set<String>.self, forKey: .folderUuids) ?? []
        filterDuration = try c.decodeIfPresent(Bool.self, forKey: .filterDuration) ?? false
        longerThan = try c.decodeIfPresent(Int32.self, forKey: .longerThan) ?? 0
        shorterThan = try c.decodeIfPresent(Int32.self, forKey: .shorterThan) ?? 0
        filterHours = try c.decodeIfPresent(Int32.self, forKey: .filterHours) ?? 0
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        groupBy = try c.decodeIfPresent(Int.self, forKey: .groupBy) ?? 0
    }

    /// True when this preset narrows nothing beyond the default — i.e. it is "All Episodes" in all
    /// but name (archived included).
    var isDefault: Bool {
        self == FilterPreset(uuid: uuid, name: name, iconId: iconId, enabled: enabled, sortOrder: sortOrder, groupBy: groupBy)
    }

    /// Whether a podcast/folder scope is set.
    var isScoped: Bool {
        !podcastUuids.isEmpty || !folderUuids.isEmpty
    }
}

// MARK: - Built-ins

extension FilterPreset {
    /// The presets that ship above the user's own. They are **seeds, not fixtures** — editable and
    /// deletable like any other.
    static var builtIns: [FilterPreset] {
        [
            FilterPreset(uuid: "preset-all", name: L10n.filterPresetAllEpisodes),
            FilterPreset(uuid: "preset-unseen", name: L10n.filterPresetUnseen, unseen: true),
            FilterPreset(uuid: "preset-downloaded", name: L10n.filterPresetDownloaded, downloadStatus: [.downloaded]),
            FilterPreset(uuid: "preset-in-progress", name: L10n.filterPresetInProgress, playingStatus: [.inProgress]),
            FilterPreset(uuid: "preset-starred", name: L10n.filterPresetStarred, starred: true)
        ]
    }

    /// The default selection — everything, unfiltered.
    static var allEpisodes: FilterPreset { builtIns[0] }
}
