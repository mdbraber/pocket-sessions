import Foundation
import GRDB
import GRDBMacros

@GRDBRecord(table: "SJFilteredPlaylist")
public class EpisodeFilter: NSObject {
    @objc public var id = 0 as Int64
    @objc public var autoDownloadEpisodes = false
    @objc public var customIcon = 0 as Int32
    @objc public var filterAllPodcasts = false
    @objc public var filterAudioVideoType = 0 as Int32
    @objc public var filterDownloaded = false
    @GRDBIgnore
    @objc public let filterDownloading = true // we no longer let the user change this, it's just always true
    @objc public var filterFinished = false
    @objc public var filterNotDownloaded = false
    @objc public var filterPartiallyPlayed = false
    @objc public var filterStarred = false
    @objc public var filterUnplayed = false
    @objc public var filterHours = 0 as Int32
    @objc public var playlistName = ""
    @objc public var sortPosition = 0 as Int32
    @objc public var sortType = 0 as Int32
    @objc public var uuid = ""
    @objc public var podcastUuids = ""
    @objc public var autoDownloadLimit = 0 as Int32
    @objc public var filterDuration = false
    @objc public var longerThan = 0 as Int32
    @objc public var shorterThan = 0 as Int32
    @objc public var syncStatus = 0 as Int32
    @objc public var wasDeleted = false
    @objc public var manual: Bool = false
    @objc public var playlistUpdateDate: Date?

    // Fork-only folder link: the folders this smart playlist tracks. The link is never
    // part of any query — the folders' podcasts are materialized into the stock (synced)
    // podcastUuids field whenever folder membership changes, so every device sees an
    // ordinary podcast-filtered playlist. Preserved across full sync via
    // copyForkOnlyFields(from:), never uploaded.
    @objc public var folderUuids = ""

    // Fork-only custom-order fields for smart playlists: when sortType is dragAndDrop,
    // positioned episodes form the "Lineup" and unpositioned matches sit in the "New" inbox
    // (unless newEpisodesAutoAdd absorbs them automatically). The insert marker state
    // (mode + last-inserted uuid) decides where "Add to lineup" places episodes.
    @objc public var newEpisodesAutoAdd = false
    @objc public var customOrderInsertMode = 2 as Int32 // PlaylistInsertMode.afterLastInserted
    @objc public var customOrderLastInsertedUuid = ""

    // Internal tracking
    @GRDBIgnore
    public var isNew: Bool = false
    @GRDBIgnore
    public var podcastSmartRuleApplied: Bool = false
    @GRDBIgnore
    public var episodesSmartRuleApplied: Bool = false
    @GRDBIgnore
    public var releaseDateSmartRuleApplied: Bool = false
    @GRDBIgnore
    public var mediaTypeSmartRuleApplied: Bool = false
    @GRDBIgnore
    public var downloadStatusSmartRuleApplied: Bool = false

    override public init() {}

    /// A new filter pre-populated with the default "match everything" rules used when creating a playlist.
    /// Callers set the name, sort position, and any distinguishing fields (e.g. `manual`, `sortType`).
    public static func makeDefault() -> EpisodeFilter {
        let filter = EpisodeFilter()
        filter.uuid = UUID().uuidString
        filter.syncStatus = SyncStatus.notSynced.rawValue
        filter.filterAllPodcasts = true
        filter.filterUnplayed = true
        filter.filterPartiallyPlayed = true
        filter.filterFinished = true
        filter.filterDownloaded = true
        filter.filterNotDownloaded = true
        filter.filterAudioVideoType = AudioVideoFilter.all.rawValue
        return filter
    }

    public func setTitle(_ title: String?, defaultTitle: String) {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            playlistName = defaultTitle

            return
        }

        playlistName = title
    }

    public func markingAsPlayedRemovesItem() -> Bool {
        !filterFinished
    }

    public func markingAsUnplayedRemovesItem() -> Bool {
        !filterUnplayed
    }

    public func deletingFileRemovesItem() -> Bool {
        !filterDownloaded
    }

    public func addPodcast(podcastUuid: String) {
        if podcastUuids.isEmpty {
            filterAllPodcasts = false
            podcastUuids = podcastUuid
        } else {
            podcastUuids.append(",\(podcastUuid)")
        }

        syncStatus = SyncStatus.notSynced.rawValue
    }

    public func removePodcast(podcastUuid: String) {
        var podcasts = podcastUuids.components(separatedBy: ",")
        podcasts.removeAll(where: { uuid -> Bool in
            podcastUuid == uuid
        })

        if podcasts.isEmpty {
            filterAllPodcasts = true
            podcastUuids = ""
        } else {
            podcastUuids = podcasts.joined(separator: ",")
        }
    }

    /// Copies the fork-only fields from another instance. Used by the full-sync path,
    /// which rebuilds playlists from the server proto (which can't carry these fields).
    public func copyForkOnlyFields(from other: EpisodeFilter) {
        folderUuids = other.folderUuids
        newEpisodesAutoAdd = other.newEpisodesAutoAdd
        customOrderInsertMode = other.customOrderInsertMode
        customOrderLastInsertedUuid = other.customOrderLastInsertedUuid
    }

    /// Convenience accessor for the fork-only insert-marker mode.
    public var insertMode: PlaylistInsertMode {
        get { PlaylistInsertMode(rawValue: customOrderInsertMode) ?? .afterLastInserted }
        set { customOrderInsertMode = newValue.rawValue }
    }

    /// Fork-only: true when this smart playlist uses the custom-order overlay (Lineup + New inbox).
    public var usesCustomOrderOverlay: Bool {
        !manual && sortType == PlaylistSort.dragAndDrop.rawValue
    }

    /// Fork-only: where the insert marker currently sits in the given lineup (ordered episode
    /// uuids). Inserts land at this index; it's also where the marker row is rendered.
    /// Floating modes fall back to top (after) / bottom (before) when the anchor episode
    /// has left the playlist.
    public func insertMarkerIndex(inLineup lineupUuids: [String]) -> Int {
        switch insertMode {
        case .top:
            return 0
        case .bottom:
            return lineupUuids.count
        case .afterLastInserted:
            guard let anchor = lineupUuids.firstIndex(of: customOrderLastInsertedUuid) else { return 0 }
            return anchor + 1
        case .beforeLastInserted:
            guard let anchor = lineupUuids.firstIndex(of: customOrderLastInsertedUuid) else { return lineupUuids.count }
            return anchor
        }
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let otherFilter = object as? EpisodeFilter else { return false }

        return otherFilter.uuid == uuid
    }

    override public var hash: Int {
        Int(truncatingIfNeeded: id)
    }
}
