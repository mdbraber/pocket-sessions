import PocketCastsDataModel
#if !os(watchOS)
import Firebase
#endif
import PocketCastsServer
import UIKit
import SwiftUI
import PocketCastsUtils

/// Per-podcast override for the fork's linked-adds switches.
enum MirrorOverride: Int, CaseIterable {
    case followGlobal = 0
    case on = 1
    case off = 2
}

class Settings: NSObject {

#if !os(watchOS)
    static var debugPlaylistsLimit = Constants.Limits.maxFilterItems
#endif

    static var isLockScreenScrubbingDisabled: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.isLockScreenScrubbingDisabled)
            NotificationCenter.default.post(name: Constants.Notifications.remoteCommandSettingsChanged, object: nil)
        }
        get {
            return UserDefaults.standard.bool(forKey: Constants.UserDefaults.isLockScreenScrubbingDisabled)
        }
    }

    static var openLinks: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.openLinksInExternalBrowser)
        }
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.openLinksInExternalBrowser)
        }
    }

    // MARK: - Library Type

    static let podcastLibraryGridTypeKey = "SJPodcastLibraryGridType"
    private static var cachedlibrarySortType: LibraryType?
    class func setLibraryType(_ type: LibraryType) {
        UserDefaults.standard.set(type.old.rawValue, forKey: Settings.podcastLibraryGridTypeKey)
        cachedlibrarySortType = type
    }

    class func libraryType() -> LibraryType {
        if let type = cachedlibrarySortType {
            return type
        }

        let storedValue = UserDefaults.standard.integer(forKey: Settings.podcastLibraryGridTypeKey)
        if let type = LibraryType(oldValue: storedValue) {
            cachedlibrarySortType = type

            return type
        }

        return LibraryType.threeByThree // default value
    }

    // MARK: - Podcast Badge

    static let badgeKey = "SJBadgeType"
    class func podcastBadgeType() -> BadgeType {
        let storedBadgeType = UserDefaults.standard.integer(forKey: Settings.badgeKey)

        if let type = BadgeType(rawValue: Int32(storedBadgeType)) {
            // Fork flag: the session-aware types read as off while library badges are
            // disabled (the stored choice survives for when the flag returns).
            if type.isSessionBased, !FeatureFlag.libraryBadges.enabled {
                return .off
            }
            return type
        }

        return .off
    }

    class func setPodcastBadgeType(_ badgeType: BadgeType) {
        UserDefaults.standard.set(badgeType.rawValue, forKey: Settings.badgeKey)
    }

    // MARK: - Up Next Auto Download

    private static let autoDownloadUpNext = "SJAutoDownloadUpNext"
    class func downloadUpNextEpisodes() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.autoDownloadUpNext)
    }

    class func setDownloadUpNextEpisodes(_ download: Bool) {
        UserDefaults.standard.set(download, forKey: Settings.autoDownloadUpNext)
        trackValueToggled(.settingsAutoDownloadUpNextToggled, enabled: download)
    }

    // MARK: - Mobile Data

    static let allowCellularDownloadKey = "SJUserCellular"
    class func mobileDataAllowed() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.allowCellularDownloadKey)
    }

    class func setMobileDataAllowed(_ allow: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(allow, forKey: Settings.allowCellularDownloadKey)

        guard userInitiated else { return }
        trackValueToggled(.settingsStorageWarnBeforeUsingDataToggled, enabled: allow)
    }

    // MARK: - Auto Download Mobile Data

    private static let allowCellularAutoDownloadKey = "SJUserCellularAutoDownload"
    class func autoDownloadMobileDataAllowed() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.allowCellularAutoDownloadKey)
    }

    class func setAutoDownloadMobileDataAllowed(_ allow: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(allow, forKey: Settings.allowCellularAutoDownloadKey)

        guard userInitiated else { return }
        trackValueToggled(.settingsAutoDownloadOnlyOnWifiToggled, enabled: !allow)
    }

    // MARK: - Auto Download

    private static let autoDownloadEnabledKey = "AutoDownloadEnabled"
    class func autoDownloadEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: Settings.autoDownloadEnabledKey) != nil else {
            return FeatureFlag.autoDownloadOnSubscribe.enabled
        }
        return UserDefaults.standard.bool(forKey: Settings.autoDownloadEnabledKey)
    }

    class func setAutoDownloadEnabled(_ allow: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(allow, forKey: Settings.autoDownloadEnabledKey)

        guard userInitiated else { return }
        trackValueToggled(.settingsAutoDownloadNewEpisodesToggled, enabled: allow)
    }

    private static let autoDownloadOnFollowKey = "AutoDownloadOnFollow"
    class func autoDownloadOnFollow() -> Bool {
        guard UserDefaults.standard.object(forKey: Settings.autoDownloadOnFollowKey) != nil else {
            return false
        }
        return UserDefaults.standard.bool(forKey: Settings.autoDownloadOnFollowKey)
    }

    class func setAutoDownloadOnFollow(_ allow: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(allow, forKey: Settings.autoDownloadOnFollowKey)

        guard userInitiated else { return }
        trackValueToggled(.settingsAutoDownloadOnFollowPodcastToggled, enabled: allow)
    }

    private static let autoDownloadLimitKey = "AutoDownloadLimit"
    class func autoDownloadLimits() -> AutoDownloadLimit {
        AutoDownloadLimit(rawValue: UserDefaults.standard.integer(forKey: Settings.autoDownloadLimitKey)) ?? .two
    }

    class func setAutoDownloadLimits(_ limit: AutoDownloadLimit) {
        UserDefaults.standard.set(limit.rawValue, forKey: Settings.autoDownloadLimitKey)
        trackValueChanged(.settingsAutoDownloadLimitDownloadsChanged, value: limit.rawValue)
    }

    class func shouldDeleteWhenPlayed() -> Bool {
        let finishedAction = UserDefaults.standard.integer(forKey: Constants.UserDefaults.episodeFinishedAction)

        return finishedAction == PodcastFinishedAction.delete.rawValue
    }

    class func setShouldDeleteWhenPlayed(_ shouldDelete: Bool) {
        let finishedAction = shouldDelete ? PodcastFinishedAction.delete : PodcastFinishedAction.doNothing

        UserDefaults.standard.setValue(finishedAction.rawValue, forKey: Constants.UserDefaults.episodeFinishedAction)
    }

    // MARK: - Default Archive Hiding

    static let defaultArchiveBehaviour = "SJDefaultArchive"
    class func showArchivedDefault() -> Bool {
        UserDefaults.standard.bool(forKey: defaultArchiveBehaviour)
    }

    class func setShowArchivedDefault(_ showArchived: Bool) {
        UserDefaults.standard.set(showArchived, forKey: defaultArchiveBehaviour)

        trackValueChanged(.settingsGeneralArchivedEpisodesChanged, value: showArchived ? "show" : "hide")
    }

    // MARK: - Primary Row Action

    static let primaryRowActionKey = "SJRowAction"
    private static var cachedPrimaryRowAction: PrimaryRowAction? // we cache this because it's used in lists
    class func primaryRowAction() -> PrimaryRowAction {
        if let action = cachedPrimaryRowAction { return action }
        let storedValue = UserDefaults.standard.integer(forKey: primaryRowActionKey)
        return PrimaryRowAction(rawValue: Int32(storedValue)) ?? .stream
    }

    class func setPrimaryRowAction(_ action: PrimaryRowAction) {
        UserDefaults.standard.set(
            action.rawValue,
            forKey: primaryRowActionKey
        )
        cachedPrimaryRowAction = action

        trackValueChanged(.settingsGeneralRowActionChanged, value: action)
    }

    // MARK: - Podcast Sort Order

    class func homeFolderSortOrder() -> LibrarySort {
        let sortInt = ServerSettings.homeGridSortOrder()
        if let librarySort = LibrarySort(oldValue: sortInt) {
            return librarySort
        }

        return .dateAddedNewestToOldest
    }

    class func setHomeFolderSortOrder(order: LibrarySort) {
        ServerSettings.setHomeGridSortOrder(order.old.rawValue, syncChange: true)
    }

    // MARK: - Podcast Grouping Default

    static let podcastGroupingDefaultKey = "SJDefaultPodcastGrouping"
    private static var cachedPodcastGrouping: PodcastGrouping?
    class func defaultPodcastGrouping() -> PodcastGrouping {
        if let grouping = cachedPodcastGrouping { return grouping }

        let storedValue = UserDefaults.standard.integer(forKey: podcastGroupingDefaultKey)
        let defaultGrouping = PodcastGrouping(rawValue: Int32(storedValue)) ?? .none
        cachedPodcastGrouping = defaultGrouping

        return defaultGrouping
    }

    class func setDefaultPodcastGrouping(_ grouping: PodcastGrouping) {
        UserDefaults.standard.set(grouping.rawValue, forKey: podcastGroupingDefaultKey)
        cachedPodcastGrouping = grouping

        trackValueChanged(.settingsGeneralEpisodeGroupingChanged, value: grouping)
    }

    // MARK: - Primary Up Next Swipe Action

    static let primaryUpNextSwipeActionKey = "SJUpNextSwipe"
    private static var cachedPrimaryUpNextSwipeAction: PrimaryUpNextSwipeAction? // we cache this because it's used in lists
    class func primaryUpNextSwipeAction() -> PrimaryUpNextSwipeAction {
        if let action = cachedPrimaryUpNextSwipeAction { return action }

        let storedValue = UserDefaults.standard.integer(forKey: primaryUpNextSwipeActionKey)
        let primaryAction = PrimaryUpNextSwipeAction(rawValue: Int32(storedValue)) ?? .playNext
        cachedPrimaryUpNextSwipeAction = primaryAction

        return primaryAction
    }

    class func setPrimaryUpNextSwipeAction(_ action: PrimaryUpNextSwipeAction) {
        UserDefaults.standard.set(action.rawValue, forKey: primaryUpNextSwipeActionKey)
        cachedPrimaryUpNextSwipeAction = action

        trackValueChanged(.settingsGeneralUpNextSwipeChanged, value: action)
    }

    // MARK: - Play Up Next On Tap

    static let playUpNextOnTapKey = "SJPlayUpNextOnTap"
    class func playUpNextOnTap() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.playUpNextOnTapKey)
    }

    class func setPlayUpNextOnTap(_ isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: Settings.playUpNextOnTapKey)
    }

    static let upNextShuffleKey = "SJUpNextShuffleKey"
    class func upNextShuffleToggle() {
        guard FeatureFlag.upNextShuffle.enabled else { return }

        let isOn = upNextShuffleEnabled()
        UserDefaults.standard.set(!isOn, forKey: Settings.upNextShuffleKey)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.upNextShuffleToggle)
    }

    class func upNextShuffleEnabled() -> Bool {
        if !FeatureFlag.upNextShuffle.enabled || !SubscriptionHelper.hasActiveSubscription() || !SyncManager.isUserLoggedIn() {
            return false
        }
        return UserDefaults.standard.bool(forKey: Settings.upNextShuffleKey)
    }

    static let playlistsBadgeKey = "SJPlaylistsBadgeType"

    /// Fork: the Playlists overview's badge type — same option set as the podcast
    /// badges. Off whenever the library-badges flag is.
    class func playlistsBadgeType() -> BadgeType {
        guard FeatureFlag.libraryBadges.enabled else { return .off }
        return BadgeType(rawValue: Int32(UserDefaults.standard.integer(forKey: Settings.playlistsBadgeKey))) ?? .off
    }

    class func setPlaylistsBadgeType(_ badgeType: BadgeType) {
        UserDefaults.standard.set(badgeType.rawValue, forKey: Settings.playlistsBadgeKey)
    }

    // MARK: - Fork: linked adds (Up Next ⇄ Session)

    static let mirrorUpNextToSessionKey = "SJMirrorUpNextToSession"
    static let mirrorSessionToUpNextKey = "SJMirrorSessionToUpNext"

    class func mirrorUpNextToSession() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.mirrorUpNextToSessionKey)
    }

    class func setMirrorUpNextToSession(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Settings.mirrorUpNextToSessionKey)
    }

    class func mirrorSessionToUpNext() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.mirrorSessionToUpNextKey)
    }

    class func setMirrorSessionToUpNext(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Settings.mirrorSessionToUpNextKey)
    }

    /// Per-podcast override: follow the global switch (live) or pin On/Off.
    class func mirrorOverride(key: String, podcastUuid: String) -> MirrorOverride {
        MirrorOverride(rawValue: UserDefaults.standard.integer(forKey: "\(key)-\(podcastUuid)")) ?? .followGlobal
    }

    class func setMirrorOverride(_ override: MirrorOverride, key: String, podcastUuid: String) {
        UserDefaults.standard.set(override.rawValue, forKey: "\(key)-\(podcastUuid)")
    }

    class func resolvedMirrorUpNextToSession(podcastUuid: String) -> Bool {
        switch mirrorOverride(key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcastUuid) {
        case .followGlobal: return mirrorUpNextToSession()
        case .on: return true
        case .off: return false
        }
    }

    class func resolvedMirrorSessionToUpNext(podcastUuid: String) -> Bool {
        switch mirrorOverride(key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcastUuid) {
        case .followGlobal: return mirrorSessionToUpNext()
        case .on: return true
        case .off: return false
        }
    }

    // MARK: - Which session playlists show in the Playlists tab

    static let showManualSessionsKey = "SJShowManualSessions"
    static let showSmartPlaylistSessionsKey = "SJShowSmartPlaylistSessions"
    static let showPodcastSessionFoldersKey = "SJShowPodcastSessionFolders"

    /// Hand-built (manual) session playlists.
    class func showManualSessions() -> Bool {
        UserDefaults.standard.object(forKey: showManualSessionsKey) as? Bool ?? true
    }
    class func setShowManualSessions(_ on: Bool) { UserDefaults.standard.set(on, forKey: showManualSessionsKey) }

    /// Sessions fed by a smart playlist (also folder / all-podcasts feeders, which are smart under the hood).
    class func showSmartPlaylistSessions() -> Bool {
        UserDefaults.standard.object(forKey: showSmartPlaylistSessionsKey) as? Bool ?? true
    }
    class func setShowSmartPlaylistSessions(_ on: Bool) { UserDefaults.standard.set(on, forKey: showSmartPlaylistSessionsKey) }

    /// Per-podcast sessions show for podcasts whose folder is selected here (e.g. "Series")…
    class func showPodcastSessionFolders() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: showPodcastSessionFoldersKey) ?? [])
    }
    class func setShowPodcastSessionFolders(_ uuids: Set<String>) {
        UserDefaults.standard.set(Array(uuids), forKey: showPodcastSessionFoldersKey)
    }

    static let showPodcastSessionPodcastsKey = "SJShowPodcastSessionPodcasts"

    /// …or for individually selected podcasts.
    class func showPodcastSessionPodcasts() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: showPodcastSessionPodcastsKey) ?? [])
    }
    class func setShowPodcastSessionPodcasts(_ uuids: Set<String>) {
        UserDefaults.standard.set(Array(uuids), forKey: showPodcastSessionPodcastsKey)
    }

    static let playlistsOptedOutOfSessionKey = "SJPlaylistsOptedOutOfSession"

    /// Fork: smart playlists the user has declared "not a session playlist". Every smart
    /// playlist can back a session by default; opting out hides its Session tab, its
    /// "Play Session" button and its chooser/CarPlay row, and stops one being created.
    /// The session's store and lineup are left untouched, so opting back in restores it.
    class func playlistsOptedOutOfSession() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: playlistsOptedOutOfSessionKey) ?? [])
    }

    class func playlistOptedOutOfSession(uuid: String) -> Bool {
        playlistsOptedOutOfSession().contains(uuid)
    }

    class func setPlaylistOptedOutOfSession(_ optedOut: Bool, uuid: String) {
        var uuids = playlistsOptedOutOfSession()
        if optedOut { uuids.insert(uuid) } else { uuids.remove(uuid) }
        UserDefaults.standard.set(Array(uuids), forKey: playlistsOptedOutOfSessionKey)
    }

    static let sessionAutoAddLimitKey = "SJSessionAutoAddLimit"

    /// Fork: auto-add to Session stops once a session's lineup holds this many
    /// episodes (manual adds are never capped). Mirrors the Up Next auto-add limit.
    class func sessionAutoAddLimit() -> Int {
        let limit = UserDefaults.standard.integer(forKey: Settings.sessionAutoAddLimitKey)
        return limit > 0 ? limit : 100
    }

    class func setSessionAutoAddLimit(_ limit: Int) {
        UserDefaults.standard.set(limit, forKey: Settings.sessionAutoAddLimitKey)
    }

    // Fork: collapsed episode-group headers per podcast (keyed by group title, which
    // is stable within a grouping mode). Purely a per-podcast display preference.
    private static func collapsedGroupsKey(_ podcastUuid: String) -> String {
        "SJPodcastCollapsedGroups-\(podcastUuid)"
    }

    class func collapsedEpisodeGroups(podcastUuid: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedGroupsKey(podcastUuid)) ?? [])
    }

    class func toggleEpisodeGroupCollapsed(podcastUuid: String, groupTitle: String) {
        var set = collapsedEpisodeGroups(podcastUuid: podcastUuid)
        if set.contains(groupTitle) { set.remove(groupTitle) } else { set.insert(groupTitle) }
        UserDefaults.standard.set(Array(set), forKey: collapsedGroupsKey(podcastUuid))
    }

    static let playbackSessionTypeKey = "SJPlaybackSessionType"
    static let playbackSessionUuidKey = "SJPlaybackSessionUuid"

    /// The active playback session, or nil when the Up Next queue plays normally. The pointer
    /// (type + uuid) syncs via ForkSettingsSync so idle devices adopt the same session framing;
    /// a device actively playing its own session is never yanked off it (see `pull`).
    class func playbackSession() -> PlaybackSession? {
        guard let typeValue = UserDefaults.standard.string(forKey: Settings.playbackSessionTypeKey),
              let type = PlaybackSessionType(rawValue: typeValue),
              let uuid = UserDefaults.standard.string(forKey: Settings.playbackSessionUuidKey)
        else {
            return nil
        }

        return PlaybackSession(type: type, uuid: uuid)
    }

    class func setPlaybackSession(_ session: PlaybackSession?) {

        if let session {
            UserDefaults.standard.set(session.type.rawValue, forKey: Settings.playbackSessionTypeKey)
            UserDefaults.standard.set(session.uuid, forKey: Settings.playbackSessionUuidKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Settings.playbackSessionTypeKey)
            UserDefaults.standard.removeObject(forKey: Settings.playbackSessionUuidKey)
        }
        UserDefaults.standard.removeObject(forKey: Settings.playbackSessionPausedKey)
        UserDefaults.standard.removeObject(forKey: Settings.playbackSessionLastEpisodeKey)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playbackSessionChanged)
    }


    static let playbackSessionLastEpisodeKey = "SJPlaybackSessionLastEpisode"

    /// The most recently played session episode — a paused session's collapsed view offers
    /// it as the "resume here" row.
    class func playbackSessionLastEpisodeUuid() -> String? {
        UserDefaults.standard.string(forKey: Settings.playbackSessionLastEpisodeKey)
    }

    class func setPlaybackSessionLastEpisodeUuid(_ uuid: String?) {
        if let uuid {
            UserDefaults.standard.set(uuid, forKey: Settings.playbackSessionLastEpisodeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Settings.playbackSessionLastEpisodeKey)
        }
    }

    static let playbackSessionPausedKey = "SJPlaybackSessionPaused"

    /// Whether the saved session is paused: it stays collapsed in Up Next while the queue
    /// plays normally, and playing one of its episodes resumes it.
    class func playbackSessionPaused() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.playbackSessionPausedKey)
    }

    class func setPlaybackSessionPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: Settings.playbackSessionPausedKey)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playbackSessionChanged)
    }

    // MARK: - Discover Region

    private static let chartRegion = "SJChartRegion"
    class func discoverRegion(discoverLayout: DiscoverLayout) -> String {
        return convertRegion(userRegion: userRegion(), discoverLayout: discoverLayout)
    }

    class func userRegion() -> String? {
        var userRegion: String?
        if let savedRegion = UserDefaults.standard.string(forKey: chartRegion) {
            userRegion = savedRegion.lowercased()
        } else if let region = (Locale.current as NSLocale).object(forKey: NSLocale.Key.countryCode) as? String {
            userRegion = region.lowercased()
        }
        return userRegion
    }

    private class func convertRegion(userRegion: String?, discoverLayout: DiscoverLayout) -> String {
        guard let userRegion else { return discoverLayout.defaultRegionCode }

        if let _ = discoverLayout.regions?[userRegion.lowercased()] {
            return userRegion
        }

        return discoverLayout.defaultRegionCode
    }

    class func setDiscoverRegion(region: String) {
        UserDefaults.standard.set(region, forKey: chartRegion)
        UserDefaults.standard.synchronize()

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.chartRegionChanged)

        if FeatureFlag.enableLocalizationHeaders.enabled {
            LocalizationHelper.update(userRegion: region)
        }
    }

    // MARK: - Auto Archiving

    static let autoArchivePlayedAfterKey = "AutoArchivePlayedAfer"
    class func autoArchivePlayedAfter() -> TimeInterval {
        UserDefaults.standard.double(forKey: Settings.autoArchivePlayedAfterKey)
    }

    class func setAutoArchivePlayedAfter(_ after: TimeInterval, userInitiated: Bool = false) {
        UserDefaults.standard.set(after, forKey: Settings.autoArchivePlayedAfterKey)

        guard userInitiated else { return }
        if let archiveTime = AutoArchiveAfterTime(rawValue: after) {
            trackValueChanged(.settingsAutoArchivePlayedChanged, value: archiveTime)
        }
    }

    static let autoArchiveInactiveAfterKey = "AutoArchiveInactiveAfer"
    class func autoArchiveInactiveAfter() -> TimeInterval {
        UserDefaults.standard.double(forKey: Settings.autoArchiveInactiveAfterKey)
    }

    class func setAutoArchiveInactiveAfter(_ after: TimeInterval, userInitiated: Bool = false) {
        UserDefaults.standard.set(after, forKey: Settings.autoArchiveInactiveAfterKey)

        guard userInitiated else { return }
        if let archiveTime = AutoArchiveAfterTime(rawValue: after) {
            trackValueChanged(.settingsAutoArchiveInactiveChanged, value: archiveTime)
        }
    }

    static let archiveStarredEpisodesKey = "ArchiveStarredEpisodes"
    class func archiveStarredEpisodes() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.archiveStarredEpisodesKey)
    }

    class func setArchiveStarredEpisodes(_ archive: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(archive, forKey: Settings.archiveStarredEpisodesKey)

        guard userInitiated else { return }
        trackValueToggled(.settingsAutoArchiveIncludeStarredToggled, enabled: archive)
    }

    // MARK: - App Info

    @objc class func appVersion() -> String {
        guard let infoDictionary = Bundle.main.infoDictionary, let shortVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            return "6.0" // this should never fail, but it's a nicer API to not return nil
        }

        return shortVersion
    }

    class func displayableVersion() -> String {
#if STAGING
        return L10n.appVersion(Settings.appVersion(), Settings.buildNumber()) + " - STAGING"
#else
        return L10n.appVersion(Settings.appVersion(), Settings.buildNumber())
#endif
    }

    class func buildNumber() -> String {
        guard let infoDictionary = Bundle.main.infoDictionary, let buildNumber = infoDictionary[kCFBundleVersionKey as String] as? String else {
            return "1" // this should never fail, but it's a nicer API to not return nil
        }

        return buildNumber
    }

    // MARK: - Sleep Time

    private static let customSleepTimeKey = "CustomSleepTime"
    class func customSleepTime() -> TimeInterval {
        let savedTime = UserDefaults.standard.double(forKey: Settings.customSleepTimeKey)
        if savedTime < Constants.Limits.minSleepTime { return Constants.Limits.minSleepTime }

        return savedTime
    }

    class func setCustomSleepTime(_ time: TimeInterval) {
        let adjustedTime = time < Constants.Limits.minSleepTime ? Constants.Limits.minSleepTime : time
        UserDefaults.standard.set(adjustedTime, forKey: "CustomSleepTime")
    }

    static var sleepTimerNumberOfEpisodes: Int {
        get {
            UserDefaults.standard.object(forKey: "sleep_timer_custom_number_of_episodes") as? Int ?? 1
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "sleep_timer_custom_number_of_episodes")
        }
    }

    // MARK: - CarPlay/Lock Screen actions

    static let mediaSessionActionsKey = "MediaSessionActions"
    class func extraMediaSessionActionsEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.mediaSessionActionsKey)
    }

    class func setExtraMediaSessionActionsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Settings.mediaSessionActionsKey)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.extraMediaSessionActionsChanged)

        Settings.trackValueToggled(.settingsGeneralExtraPlaybackActionsToggled, enabled: enabled)
    }

    // MARK: - Legacy Bluetooth Support

    static let legacyBtSupportKey = "LegacyBtSupport"
    class func legacyBluetoothModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.legacyBtSupportKey)
    }

    class func setLegacyBluetoothModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Settings.legacyBtSupportKey)
        Settings.trackValueToggled(.settingsGeneralLegacyBluetoothToggled, enabled: enabled)
    }

    // MARK: - Publish Chapter Titles

    static let publishChapterTitlesKey = "PublishChapterTitles"
    class func publishChapterTitlesEnabled() -> Bool {
        if let isEnabled = UserDefaults.standard.value(forKey: Settings.publishChapterTitlesKey) as? Bool {
            return isEnabled
        }

        return true
    }

    class func setPublishChapterTitlesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Settings.publishChapterTitlesKey)
    }

    // MARK: - User Episode Settings

    public static let userEpisodeSortByKey = "UserEpisodeSortBy"
    class func userEpisodeSortBy() -> Int32 {
        Int32(UserDefaults.standard.integer(forKey: userEpisodeSortByKey))
    }

    class func setUserEpisodeSortBy(_ value: Int32) {
        UserDefaults.standard.set(value, forKey: userEpisodeSortByKey)
    }

    private static let userEpisodeAutoUploadKey = "UserEpisodeAutoUpload"
    class func userFilesAutoUpload() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeAutoUploadKey)
    }

    class func setUserEpisodeAutoUpload(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeAutoUploadKey)
        trackValueToggled(.settingsFilesAutoUploadToCloudToggled, enabled: value)
    }

    static let userEpisodeAutoAddToUpNextKey = "UserEpisodeAutoAddToUpNext"
    class func userEpisodeAutoAddToUpNext() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeAutoAddToUpNextKey)
    }

    class func setUserEpisodeAutoAddToUpNext(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeAutoAddToUpNextKey)
        trackValueToggled(.settingsFilesAutoAddUpNextToggled, enabled: value)
    }

    static let userEpisodeRemoveFileAfterPlayingKey = "UserEpisodeRemoveFileAfterPlaying"
    class func userEpisodeRemoveFileAfterPlaying() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeRemoveFileAfterPlayingKey)
    }

    class func setUserEpisodeRemoveFileAfterPlaying(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeRemoveFileAfterPlayingKey)
        trackValueToggled(.settingsFilesDeleteLocalFileAfterPlayingToggled, enabled: value)
    }

    static let userEpisodeRemoveFromCloudAfterPlayingKey = "UserEpisodeRemoveFromCloudAfterPlaying"
    class func userEpisodeRemoveFromCloudAfterPlaying() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeRemoveFromCloudAfterPlayingKey)
    }

    class func setUserEpisodeRemoveFromCloudAfterPlayingKey(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeRemoveFromCloudAfterPlayingKey)
        trackValueToggled(.settingsFilesDeleteCloudFileAfterPlayingToggled, enabled: value)
    }

    // MARK: - Full Player Chapters Expanded

    private static let playerChaptersExpandedKey = "PlayerChaptersExpanded"
    class func playerChaptersExpanded() -> Bool {
        if let expanded = UserDefaults.standard.value(forKey: playerChaptersExpandedKey) as? Bool {
            return expanded
        }

        return true
    }

    class func setPlayerChaptersExpanded(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: playerChaptersExpandedKey)
    }

    // MARK: Subscription Cancelled Acknowledgement

    private static let subscriptionCancelledAcknowledgedKey = "SJCancelledAcknowledged"
    class func setSubscriptionCancelledAcknowledged(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: subscriptionCancelledAcknowledgedKey)
    }

    class func subscriptionCancelledAcknowledged() -> Bool {
        UserDefaults.standard.bool(forKey: subscriptionCancelledAcknowledgedKey)
    }

    private static let subscriptionCancelledSurveyShowedKey = "SJCancelledSurveyShowed"
    static var subscriptionCancelledSurveyShown: Bool {
        get {
            UserDefaults.standard.bool(forKey: subscriptionCancelledSurveyShowedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: subscriptionCancelledSurveyShowedKey)
        }
    }

    // MARK: Promotion Finished Acknowledgement

    class func setPromotionFinishedAcknowledged(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Constants.UserDefaults.promotionFinishedAcknowledged)
    }

    class func promotionFinishedAcknowledged() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaults.promotionFinishedAcknowledged)
    }

    // MARK: Plus Info Closed

    private static let plusInfoFilesSettingsClosedKey = "PlusInfoClosedFileSettings"
    class func plusInfoDismissedOnFilesSettings() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.plusInfoFilesSettingsClosedKey)
    }

    class func setPlusInfoDismissedOnFilesSettings(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Settings.plusInfoFilesSettingsClosedKey)
    }

    private static let plusInfoFilesAddClosedKey = "PlusInfoClosedFileAdd"
    class func plusInfoDismissedOnFilesAdd() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.plusInfoFilesAddClosedKey)
    }

    class func setPlusInfoDismissedOnFilesAdd(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Settings.plusInfoFilesAddClosedKey)
    }

    private static let plusInfoAppearanceClosedKey = "PlusInfoClosedAppearance"
    class func plusInfoDismissedOnAppearance() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.plusInfoAppearanceClosedKey)
    }

    class func setPlusInfoDismissedOnAppearance(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Settings.plusInfoAppearanceClosedKey)
    }

    private static let plusInfoWatchClosedKey = "PlusInfoClosedWatch"
    class func plusInfoDismissedOnWatch() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.plusInfoWatchClosedKey)
    }

    class func setPlusInfoDismissedOnWatch(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Settings.plusInfoWatchClosedKey)
    }

    private static let plusInfoProfileClosedKey = "PlusInfoClosedProfile"
    class func plusInfoDismissedOnProfile() -> Bool {
        UserDefaults.standard.bool(forKey: Settings.plusInfoProfileClosedKey)
    }

    class func setPlusInfoDismissedOnProfile(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Settings.plusInfoProfileClosedKey)
    }

    class func uniqueAppId() -> String? {
        if let appId = UserDefaults.standard.object(forKey: Constants.UserDefaults.appId) as? String {
            return appId
        }

        return nil
    }

    // MARK: What's new

    private static let whatsNewLastAcknowledgedKey = "SJWhatsNewLastAcknowledged"

    class func setWhatsNewLastAcknowledged(_ value: Int) {
        UserDefaults.standard.set(value, forKey: whatsNewLastAcknowledgedKey)
    }

    class func whatsNewLastAcknowledged() -> Int {
        UserDefaults.standard.integer(forKey: whatsNewLastAcknowledgedKey)
    }


    private static let lastWhatsNewShownKey = "LastWhatsNewShown"
    class var lastWhatsNewShown: String? {
        set {
            UserDefaults.standard.setValue(newValue, forKey: lastWhatsNewShownKey)
            UserDefaults.standard.synchronize()
        }

        get {
            UserDefaults.standard.string(forKey: lastWhatsNewShownKey)
        }
    }

    class func setShouldFollowSystemTheme(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Constants.UserDefaults.shouldFollowSystemThemeKey)
    }

    class func shouldFollowSystemTheme() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaults.shouldFollowSystemThemeKey)
    }

    // MARK: Player Actions

    fileprivate static let playerActionsKey = "PlayerActions"
    class func playerActions() -> [PlayerAction] {
        let defaultActions = PlayerAction.defaultActions.filter { $0.isAvailable }

        let playerActions = UserDefaults.standard.playerActions ?? defaultActions

        return playerActions + defaultActions.filter { !playerActions.contains($0) }
    }

    class func updatePlayerActions(_ actions: [PlayerAction]) {
        let actionInts = actions.map(\.intValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.playerActionsKey)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playerActionsUpdated)
    }

    // MARK: Multi Select Gesture

    static let multiSelectGestureKey = "MultiSelectGestureEnabled"
    class func multiSelectGestureEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: multiSelectGestureKey)
    }

    class func setMultiSelectGestureEnabled(_ enabled: Bool, userInitiated: Bool = false) {
        UserDefaults.standard.set(enabled, forKey: multiSelectGestureKey)

        guard userInitiated else { return }
        Settings.trackValueToggled(.settingsGeneralMultiSelectGestureToggled, enabled: enabled)
    }

    // MARK: Multi Select Actions

    private static let multiSelectActionsKey = "MultiSelectActions"
    class func multiSelectActions() -> [MultiSelectAction] {
        let defaultActions: [MultiSelectAction] = [.addToSession, .removeFromSession, .markAsSeen, .markAsUnseen, .playNext, .playLast, .removeFromUpNext, .addToPlaylist, .download, .archive, .share, .markAsPlayed, .markAsUnplayed, .star]
        guard let savedInts = UserDefaults.standard.object(forKey: Settings.multiSelectActionsKey) as? [Int32] else {
            return defaultActions
        }

        let actions = savedInts.compactMap { MultiSelectAction(rawValue: $0) }

        // Make sure new items are shown
        return actions + defaultActions.filter { !actions.contains($0) }
    }

    class func updateMultiSelectActions(_ actions: [MultiSelectAction]) {
        let actionInts = actions.map(\.rawValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.multiSelectActionsKey)
    }

    private static let listeningHistoryMultiSelectActionsKey = "ListeningHistoryMultiSelectActions"
    class func listeningHistoryMultiSelectActions() -> [MultiSelectAction] {
        let defaultActions: [MultiSelectAction] = [.addToSession, .playNext, .playLast, .removeFromUpNext, .download, .archive, .share, .removeListeningHistory, .markAsPlayed, .star]
        guard let savedInts = UserDefaults.standard.object(forKey: Settings.listeningHistoryMultiSelectActionsKey) as? [Int32] else {
            return defaultActions
        }

        let actions = savedInts.compactMap { MultiSelectAction(rawValue: $0) }

        // Make sure new items are shown
        return actions + defaultActions.filter { !actions.contains($0) }
    }

    class func updateListeningHistoryMultiSelectActions(_ actions: [MultiSelectAction]) {
        let actionInts = actions.map(\.rawValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.listeningHistoryMultiSelectActionsKey)
    }

    private static let filesMultiSelectActionsKey = "FilesMultiSelectActionsV2"
    class func fileMultiSelectActions() -> [MultiSelectAction] {
        guard let savedInts = UserDefaults.standard.object(forKey: Settings.filesMultiSelectActionsKey) as? [Int32] else {
            return [.playNext, .playLast, .download, .markAsPlayed, .delete]
        }

        let actions = savedInts.compactMap { MultiSelectAction(rawValue: $0) }

        return actions
    }

    class func updateFilesMultiSelectActions(_ actions: [MultiSelectAction]) {
        let actionInts = actions.map(\.rawValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.filesMultiSelectActionsKey)
    }

    // Fork: multi-select actions for session rows — aligned with the session swipe
    // actions (no queue moves/removal; sessions aren't queue rows).
    private static let sessionMultiSelectActionsKey = "SessionMultiSelectActions"
    class func sessionMultiSelectActions() -> [MultiSelectAction] {
        let defaultActions: [MultiSelectAction] = [.removeFromSession, .playNext, .playLast, .download, .markAsPlayed, .archive, .addToPlaylist, .star]
        // Everything here is already in a session, and session rows aren't queue rows — so
        // "Add to Session" and the queue-structural moves never make sense in this world.
        // Filtering here (not just in the default) also scrubs a stale or synced saved list.
        let excluded: Set<MultiSelectAction> = [.addToSession, .moveToTop, .moveToBottom, .removeFromUpNext]
        let saved = (UserDefaults.standard.object(forKey: Settings.sessionMultiSelectActionsKey) as? [Int32])?.compactMap { MultiSelectAction(rawValue: $0) }
        let actions = saved ?? defaultActions
        // Keep saved order, append any newly added defaults, then drop the inapplicable ones.
        return (actions + defaultActions.filter { !actions.contains($0) }).filter { !excluded.contains($0) }
    }

    class func updateSessionMultiSelectActions(_ actions: [MultiSelectAction]) {
        let actionInts = actions.map(\.rawValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.sessionMultiSelectActionsKey)
    }

    private static let upNextMultiSelectActionsKey = "UpNextMultiSelectActions"
    class func upNextMultiSelectActions() -> [MultiSelectAction] {
        let defaultActions: [MultiSelectAction] = [.moveToTop, .moveToBottom, .removeFromUpNext, .addToSession, .download, .markAsPlayed, .archive, .addToPlaylist, .star]
        // Everything here is already queued, so "Add to Up Next" (Play Next / Play Last) is
        // redundant with the move actions and never makes sense in this world. Filtering here
        // (not just in the default) also scrubs a stale or synced saved list.
        let excluded: Set<MultiSelectAction> = [.playNext, .playLast]
        let saved = (UserDefaults.standard.object(forKey: Settings.upNextMultiSelectActionsKey) as? [Int32])?.compactMap { MultiSelectAction(rawValue: $0) }
        let actions = saved ?? defaultActions
        // Keep saved order, append any newly added defaults, then drop the inapplicable ones.
        return (actions + defaultActions.filter { !actions.contains($0) }).filter { !excluded.contains($0) }
    }

    class func updateUpNextMultiSelectActions(_ actions: [MultiSelectAction]) {
        let actionInts = actions.map(\.rawValue)
        UserDefaults.standard.set(actionInts, forKey: Settings.upNextMultiSelectActionsKey)
    }

    // MARK: - Password changed and watch requires update

    class func loginDetailsUpdated() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaults.loginDetailsUpdated)
    }

    class func clearLoginDetailsUpdated() {
        UserDefaults.standard.set(false, forKey: Constants.UserDefaults.loginDetailsUpdated)
    }

    class func setLoginDetailsUpdated() {
        UserDefaults.standard.set(true, forKey: Constants.UserDefaults.loginDetailsUpdated)
    }

    // MARK: - Watch number of episodes to auto sync from the Up Next queue

    class func setWatchAutoDownloadUpNextEnabled(isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: Constants.UserDefaults.watchAutoDownloadUpNextEnabled)

        trackValueToggled(.settingsAppleWatchAutoDownloadUpNextToggled, enabled: isEnabled)
    }

    class func watchAutoDownloadUpNextEnabled() -> Bool {
        guard let isEnabled = UserDefaults.standard.object(forKey: Constants.UserDefaults.watchAutoDownloadUpNextEnabled) as? Bool else {
            return false
        }

        return isEnabled
    }

    class func setWatchAutoDownloadUpNextCount(numEpisodes: Int) {
        UserDefaults.standard.set(numEpisodes, forKey: Constants.UserDefaults.watchAutoDownloadUpNextCount)
        trackValueChanged(.settingsAppleWatchAutoDownloadEpisodesChanged, value: numEpisodes)
    }

    class func watchAutoDownloadUpNextCount() -> Int {
        guard let numEpisodes = UserDefaults.standard.object(forKey: Constants.UserDefaults.watchAutoDownloadUpNextCount) as? Int else {
            return 3
        }

        return numEpisodes
    }

    class func setWatchAutoDeleteUpNext(isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: Constants.UserDefaults.watchAutoDeleteUpNext)
        trackValueToggled(.settingsAppleWatchAutoDownloadDeleteDownloadsToggled, enabled: isEnabled)
    }

    class func watchAutoDeleteUpNext() -> Bool {
        guard let isEnabled = UserDefaults.standard.object(forKey: Constants.UserDefaults.watchAutoDeleteUpNext) as? Bool else {
            return true
        }

        return isEnabled
    }

    // MARK: - App Store Review Requests

    class func addReviewRequested() {
        var reviewRequestDates = Self.reviewRequestDates()
        reviewRequestDates.append(Date())
        UserDefaults.standard.set(reviewRequestDates, forKey: Constants.UserDefaults.reviewRequestDates)
    }

    class func reviewRequestDates() -> [Date] {
        UserDefaults.standard.array(forKey: Constants.UserDefaults.reviewRequestDates) as? [Date] ?? [Date]()
    }

    class func resetReviewRequests() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.reviewRequestDates)
    }

    // MARK: - User Satisfaction Survey

    class func addSurveyPresented() {
        var surveyDates = Self.surveyPresentationDates()
        surveyDates.append(Date())
        UserDefaults.standard.set(surveyDates, forKey: Constants.UserDefaults.surveyPresentationDates)
    }

    class func surveyPresentationDates() -> [Date] {
        UserDefaults.standard.array(forKey: Constants.UserDefaults.surveyPresentationDates) as? [Date] ?? [Date]()
    }

    class func lastSurveyNotReallyDate() -> Date? {
        UserDefaults.standard.object(forKey: Constants.UserDefaults.lastSurveyNotReallyDate) as? Date
    }

    class func setSurveyNotReallyResponse() {
        UserDefaults.standard.set(Date(), forKey: Constants.UserDefaults.lastSurveyNotReallyDate)
    }

    class func resetSurveyData() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.surveyPresentationDates)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastSurveyNotReallyDate)
    }

    // MARK: - Tracks

    class func setAnalytics(optOut: Bool) {
        UserDefaults.standard.set(optOut, forKey: Constants.UserDefaults.analyticsOptOut)
    }

    class func analyticsOptOut() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaults.analyticsOptOut)
    }

    // MARK: - Sleep Timer (internal)

    class var sleepTimerFinishedDate: Date? {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.sleepTimerFinishedDate)
        }

        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.sleepTimerFinishedDate) as? Date
        }
    }

    class var sleepTimerLastSetting: SleepTimerManager.SleepTimerSetting? {
        set {
            UserDefaults.standard.setJSONObject(newValue, forKey: Constants.UserDefaults.sleepTimerSetting)
        }

        get {
            try? UserDefaults.standard.jsonObject(SleepTimerManager.SleepTimerSetting.self, forKey: Constants.UserDefaults.sleepTimerSetting)
        }
    }

    // MARK: - End of Year 2022

    class func showBadgeForEndOfYear(_ year: Int) -> Bool {
        let key = String(format: Constants.UserDefaults.showBadgeForEndOfYear, year)
        return UserDefaults.standard.bool(forKey: key)
    }

    class func setShowBadgeForEndOfYear(_ newValue: Bool, year: Int) {
        let key = String(format: Constants.UserDefaults.showBadgeForEndOfYear, year)
        UserDefaults.standard.set(newValue, forKey: key)
    }

    class func hasShownModalForEndOfYear(_ year: Int) -> Bool {
        let key = String(format: Constants.UserDefaults.modalHasBeenShown, year)
        return UserDefaults.standard.bool(forKey: key)
    }

    class func setHasShownModalForEndOfYear(_ newValue: Bool, year: Int) {
        let key = String(format: Constants.UserDefaults.modalHasBeenShown, year)
        UserDefaults.standard.set(newValue, forKey: key)
    }

    class func hasSyncedEpisodesForPlayback(year: Int) -> Bool {
        let key = String(format: Constants.UserDefaults.hasSyncedEpisodesForPlayback, year)
        return UserDefaults.standard.bool(forKey: key)
    }

    class func setHasSyncedEpisodesForPlayback(_ newValue: Bool, year: Int) {
        let key = String(format: Constants.UserDefaults.hasSyncedEpisodesForPlayback, year)
        UserDefaults.standard.set(newValue, forKey: key)
    }

    class func hasSyncedEpisodesForPlaybackAsPlusUser(year: Int) -> Bool {
        let key = String(format: Constants.UserDefaults.hasSyncedEpisodesForPlaybackAsPlusUser, year)
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Whether the user was plus or not by the time the sync happened
    class func setHasSyncedEpisodesForPlaybackAsPlusUser(_ newValue: Bool, year: Int) {
        let key = String(format: Constants.UserDefaults.hasSyncedEpisodesForPlaybackAsPlusUser, year)
        UserDefaults.standard.set(newValue, forKey: key)
    }

    class var top5PodcastsListLink: String? {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.top5PodcastsListLink)
        }

        get {
            UserDefaults.standard.string(forKey: Constants.UserDefaults.top5PodcastsListLink)
        }
    }

    static var shouldShowInitialOnboardingFlow: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.shouldShowInitialOnboardingFlow)
        }
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.shouldShowInitialOnboardingFlow)
        }
    }

    static var hasSeenInitialOnboardingBefore: Bool {
        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.shouldShowInitialOnboardingFlow) != nil
        }
    }

    // MARK: - Embedded Artwork

    static var loadEmbeddedImages: Bool {
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.loadEmbeddedImages)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.loadEmbeddedImages)
            Settings.trackValueToggled(.settingsAppearanceUseEmbeddedArtworkToggled, enabled: newValue)
        }
    }

    // MARK: - Autoplay

    static var autoplay: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.autoplay)
        }
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.autoplay)
        }
    }

    // MARK: - Audio only

    /// When enabled, video episodes play as audio only. Backed by `ServerSettings` so it syncs with the server.
    static var audioOnly: Bool {
        set {
            ServerSettings.setAudioOnly(newValue)
        }
        get {
            ServerSettings.audioOnly()
        }
    }

    // MARK: - Sleep Timer

    static var autoRestartSleepTimer: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.autoRestartSleepTimer)
        }
        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.autoRestartSleepTimer) as? Bool ?? true
        }
    }

    static var shakeToRestartSleepTimer: Bool {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.shakeToRestartSleepTimer)
        }
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.shakeToRestartSleepTimer)
        }
    }

    // MARK: - Headphone Controls

    static var headphonesPreviousAction: HeadphoneControlAction {
        get {
            Constants.UserDefaults.headphones.previousAction.unlockedValue
        }

        set {
            Constants.UserDefaults.headphones.previousAction.save(newValue)
        }
    }

    static var headphonesNextAction: HeadphoneControlAction {
        get {
            Constants.UserDefaults.headphones.nextAction.unlockedValue
        }

        set {
            Constants.UserDefaults.headphones.nextAction.save(newValue)
        }
    }


    /// Returns whether the bookmark creation sound option is enabled
    static var isPlayBookmarkCreationSoundAvailable: Bool {
        [Settings.headphonesNextAction, Settings.headphonesPreviousAction].contains(.addBookmark)
    }

    /// Determines if we should play the sound when a bookmark is created
    static var shouldPlayBookmarkSound: Bool {
        isPlayBookmarkCreationSoundAvailable && playBookmarkCreationSound
    }

    static var playBookmarkCreationSound: Bool {
        get {
            Constants.UserDefaults.bookmarks.creationSound.value
        }

        set {
            Constants.UserDefaults.bookmarks.creationSound.save(newValue)
        }
    }

    static var darkUpNextTheme: Bool {
        get {
            Constants.UserDefaults.appearance.darkUpNextTheme.value
        }

        set {
            Constants.UserDefaults.appearance.darkUpNextTheme.save(newValue)
        }
    }

    static var tabBarMinimizingEnabled: Bool {
        get { Constants.UserDefaults.appearance.tabBarMinimizingEnabled.value }
        set { Constants.UserDefaults.appearance.tabBarMinimizingEnabled.save(newValue) }
    }

    static var skipBackTime: Int {
        get {
            ServerSettings.skipBackTime()
        }
        set {
            ServerSettings.setSkipBackTime(newValue)
        }
    }

    static var skipForwardTime: Int {
        get {
            ServerSettings.skipForwardTime()
        }
        set {
            ServerSettings.setSkipForwardTime(newValue)
        }
    }

    static var playerBookmarksSort: Binding<BookmarkSortOption> {
        Binding {
            Constants.UserDefaults.bookmarks.playerSort.value
        } set: { newValue in
            Constants.UserDefaults.bookmarks.playerSort.save(newValue)
        }
    }

    static var episodeBookmarksSort: Binding<BookmarkSortOption> {
        Binding {
            Constants.UserDefaults.bookmarks.episodeSort.value
        } set: { newValue in
            Constants.UserDefaults.bookmarks.episodeSort.save(newValue)
        }
    }

    static var podcastBookmarksSort: Binding<BookmarkSortOption> {
        Binding {
            Constants.UserDefaults.bookmarks.podcastSort.value
        } set: { newValue in
            Constants.UserDefaults.bookmarks.podcastSort.save(newValue)
        }
    }

    static var profileBookmarksSort: Binding<BookmarkSortOption> {
        Binding {
            Constants.UserDefaults.bookmarks.profileSort.value
        } set: { newValue in
            Constants.UserDefaults.bookmarks.profileSort.save(newValue)
        }
    }

    static var appBadge: AppBadge? {
        get {
            AppBadge(rawValue: Int32(UserDefaults.standard.integer(forKey: Constants.UserDefaults.appBadge)))
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: Constants.UserDefaults.appBadge)
        }
    }

    static var appBadgeFilterUuid: String? {
        get {
            UserDefaults.standard.string(forKey: Constants.UserDefaults.appBadgeFilterUuid)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.appBadgeFilterUuid)
        }
    }

    // MARK: - Kids Profile

    static var shouldHideBanner: Bool {
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaults.kidsProfile.shouldHideBanner)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.kidsProfile.shouldHideBanner)
        }
    }

    // MARK: - Referrals Show Tip

    static var shouldShowReferralsTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.referrals.showTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.referrals.showTip)
        }
    }

    // MARK: - Referrals Show Tip

    static var referralURL: String? {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.referrals.claimURL) as? String
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.referrals.claimURL)
        }
    }

    // MARK: - Podcast Feed Reload

    static var shouldShowPodcastFeeReloadTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.podcastFeedReload.showTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.podcastFeedReload.showTip)
        }
    }

    // MARK: - Manage Downloads

    class var manageDownloadsLastCheckDate: Date? {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.manageDownloads.lastCheckDate)
        }

        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.manageDownloads.lastCheckDate) as? Date
        }
    }

    // MARK: - Smart Folders Upsell display
    class var suggestedFoldersLastUpsellDate: Date? {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.suggestedFolders.lastUpsellDate)
        }

        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.suggestedFolders.lastUpsellDate) as? Date
        }
    }

    class var suggestedFoldersUpsellCount: Int {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.suggestedFolders.upsellCount)
        }

        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.suggestedFolders.upsellCount) as? Int ?? 0
        }
    }

    class var suggestedFoldersLastPodcastsUsed: String? {
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.suggestedFolders.lastPodcastsUsed)
        }

        get {
            UserDefaults.standard.object(forKey: Constants.UserDefaults.suggestedFolders.lastPodcastsUsed) as? String
        }
    }

    // MARK: - Podcast View Changes Tip

    static var shouldShowPodcastViewChangesTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.podcastViewChanges.showTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.podcastViewChanges.showTip)
        }
    }

    // MARK: - Recent Played Sorting Tip

    static var shouldShowRecentlyPlayedSortingTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.shouldShowRecentlyPlayedSortingTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.shouldShowRecentlyPlayedSortingTip)
        }
    }

    // MARK: - Up Next Sort by Duration Tip

    // Defaults to true so upgrading users are told about the new duration sort once; AppDelegate suppresses it for fresh installs.
    static var shouldShowUpNextSortDurationTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.shouldShowUpNextSortDurationTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.shouldShowUpNextSortDurationTip)
        }
    }

    // MARK: - Playlists

    static var shouldShowNewFilterTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.newFilterTip) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.newFilterTip)
        }
    }

    static var shouldShowNewFilterTipInCreationView: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.newFilterTipCreationView) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.newFilterTipCreationView)
        }
    }

    static var shouldShowDragAndDropTip: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.playlistDragAndDropTip) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.playlistDragAndDropTip)
        }
    }

    static var shouldShowPlaylistsOnboarding: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.playlistsOnboarding) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.playlistsOnboarding)
        }
    }

    static var firstTimePlaylistCreated: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.firstTimePlaylistCreated) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.firstTimePlaylistCreated)
        }
    }

    static var saveCurrentUpNextQueueIntoPlaylist: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.saveCurrentUpNextQueueIntoPlaylist) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.saveCurrentUpNextQueueIntoPlaylist)
        }
    }

    static var shouldResultEndOfYearSyncStatus: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.shouldResultEndOfYearSyncStatus) as? Bool ?? true
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.shouldResultEndOfYearSyncStatus)
        }
    }

    // MARK: - Debug IAP in TF builds

    static var shouldEnableIAPInTestFlightBuilds: Bool = false

    // MARK: - Informational Banner
#if !os(watchOS) && !APPCLIP && !os(tvOS)
    static func dismissBanner(for type: InformationalBannerType) {
        UserDefaults.standard.set(true, forKey: "kInformational\(type.rawValue.capitalized)Banner")
    }

    static func shouldShowBanner(for type: InformationalBannerType) -> Bool {
        return !UserDefaults.standard.bool(forKey: "kInformational\(type.rawValue.capitalized)Banner")
    }
#endif

    // MARK: - Notifications
    static var notificationsNewEpisodes: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.newEpisodes) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.newEpisodes)
        }
    }

    static var notificationsDailyReminders: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.dailyReminders) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.dailyReminders)
        }
    }

    static var notificationsNewFeaturesAndTips: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.newFeaturesAndTips) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.newFeaturesAndTips)
        }
    }

    static var notificationsRecommendations: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.recommendations) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.recommendations)
        }
    }

    static var notificationsOffers: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.offers) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.offers)
        }
    }

    static var notificationsLastTriggerDate: [String: Date] {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.notifications.triggerDates) as? [String: Date] ?? [:]
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.notifications.triggerDates)
        }
    }

    // MARK: - Encourage Account Creation

    static var hasShownInformationalViewModal: Bool {
        get {
            UserDefaults.standard.value(forKey: Constants.UserDefaults.informationalModal.hasShownViewModal) as? Bool ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: Constants.UserDefaults.informationalModal.hasShownViewModal)
        }
    }

    // MARK: - VoiceBoostN

    static var isVoiceBoostNEnabled: Bool {
        get {
            guard FeatureFlag.voiceBoostN.enabled else { return false }
            if UserDefaults.standard.object(forKey: Constants.UserDefaults.voiceBoostNEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Constants.UserDefaults.voiceBoostNEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.voiceBoostNEnabled)
            FileLog.shared.addMessage("[Settings] VoiceBoostN \(newValue ? "enabled" : "disabled")")
        }
    }

    // MARK: - Database (internal)

    class var upgradedIndexes: Bool {
        set {
            UserDefaults.standard.setValue(newValue, forKey: "upgraded_indexes_v4")
        }

        get {
            UserDefaults.standard.bool(forKey: "upgraded_indexes_v4")
        }
    }

    class var lastAppVersionThatRunVacuum: String? {
        set {
            UserDefaults.standard.setValue(newValue, forKey: "last_app_version_that_run_vacuum")
        }

        get {
            UserDefaults.standard.string(forKey: "last_app_version_that_run_vacuum")
        }
    }

    // MARK: - Variables that are loaded/changed through Firebase

    #if !os(watchOS)
        class func minTimeBetweenProgressSaves() -> TimeInterval {
            remoteMsToTime(key: Constants.RemoteParams.periodicSaveTimeMs)
        }

        class func podcastSearchDebounceTime() -> TimeInterval {
            if FeatureFlag.searchPredictive.enabled {
                return 0.2
            } else {
                return remoteMsToTime(key: Constants.RemoteParams.podcastSearchDebounceMs)
            }
        }

        class func episodeSearchDebounceTime() -> TimeInterval {
            remoteMsToTime(key: Constants.RemoteParams.episodeSearchDebounceMs)
        }

        static var endOfYearRequireAccount: Bool {
            let remote = RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.endOfYearRequireAccount)
            return remote.boolValue
        }

        static var addMissingEpisodes: Bool {
            let remote = RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.addMissingEpisodes)
            return remote.boolValue
        }

        static var plusCloudStorageLimit: Int {
            RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.customStorageLimitGB).numberValue.intValue
        }

        static var patronCloudStorageLimit: Int {
            RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.patronCloudStorageGB).numberValue.intValue
        }

        static var errorLogoutHandling: Bool {
            return RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.errorLogoutHandling).boolValue
        }

    static var slumberPromoCode: String? {
        RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.slumberStudiosPromoCode).stringValue
    }

        private class func remoteMsToTime(key: String) -> TimeInterval {
            let remoteMs = RemoteConfig.remoteConfig().configValue(forKey: key)

            return TimeInterval(remoteMs.numberValue.doubleValue / 1000)
        }
    #endif
}

extension Settings {
    static func trackValueChanged(_ event: AnalyticsEvent, value: Any) {
        Analytics.track(event, properties: ["value": value])
    }

    static func trackValueToggled(_ event: AnalyticsEvent, enabled: Bool) {
        Analytics.track(event, properties: ["enabled": enabled])
    }
}

#if !os(watchOS) && !os(tvOS)
extension L10n {
    static var plusCloudStorageLimit: String {
        plusCloudStorageLimitFormat(Settings.plusCloudStorageLimit.localized())
    }

    static var patronCloudStorageLimit: String {
        plusCloudStorageLimitFormat(Settings.patronCloudStorageLimit.localized())
    }
}
#endif

extension HeadphoneControl {
    init(action: HeadphoneControlAction) {
        switch action {
        case .addBookmark:
            self = .addBookmark
        case .nextChapter:
            self = .nextChapter
        case .previousChapter:
            self = .previousChapter
        case .skipBack:
            self = .skipBack
        case .skipForward:
            self = .skipForward
        }
    }

    var action: HeadphoneControlAction {
        switch self {
        case .addBookmark:
            return .addBookmark
        case .nextChapter:
            return .nextChapter
        case .previousChapter:
            return .previousChapter
        case .skipBack:
            return .skipBack
        case .skipForward:
            return .skipForward
        }
    }
}

extension UserDefaults {
    var playerActions: [PlayerAction]? {
        guard let savedInts = UserDefaults.standard.object(forKey: Settings.playerActionsKey) as? [Int] else {
            return nil
        }

        return savedInts
            .compactMap { PlayerAction(int: $0) }
            .filter { $0.isAvailable }
    }
}

// MARK: - Playback Session

enum PlaybackSessionType: String {
    case podcast
    case playlist
    case smartPlaylist
}

/// Supplies a session's episodes in display order. The main app injects an implementation
/// at launch (`EpisodesDataManager`); targets without one simply never advance a session.
protocol PlaybackSessionEpisodeSource {
    func orderedEpisodes(for session: PlaybackSession) -> [BaseEpisode]
}

/// A temporary playback source that plays instead of the Up Next queue: a podcast (in its
/// own sort order), a manual playlist, or a smart playlist. The queue is never modified;
/// when the session runs out of unfinished episodes, playback returns to the queue.
struct PlaybackSession: Equatable {
    let type: PlaybackSessionType
    let uuid: String

    /// Injected by the app at launch; see `PlaybackSessionEpisodeSource`.
    static var episodeSource: PlaybackSessionEpisodeSource?

    var title: String? {
        switch type {
        case .podcast:
            return DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true)?.title
        case .playlist, .smartPlaylist:
            return DataManager.sharedManager.findPlaylist(uuid: uuid)?.playlistName
        }
    }

    /// The session's full episode list in display order (empty without an injected source).
    func orderedEpisodes() -> [BaseEpisode] {
        Self.episodeSource?.orderedEpisodes(for: self) ?? []
    }

    /// The session's unfinished episodes in order, excluding the given (currently playing)
    /// one. Episodes only leave the session when they finish — jumping around the list
    /// doesn't discard the ones skipped over.
    func remainingEpisodes(excluding episodeUuid: String?) -> [BaseEpisode] {
        orderedEpisodes().filter { !$0.played() && $0.uuid != episodeUuid }
    }

    /// The episode to play after the given one finishes: the first unfinished episode
    /// after it in the session's order, wrapping back to earlier unfinished episodes when
    /// the tail is done. nil only when everything is finished (the session is over).
    func nextEpisode(after episodeUuid: String?) -> BaseEpisode? {
        let episodes = orderedEpisodes()
        let isCandidate: (BaseEpisode) -> Bool = { !$0.played() && $0.uuid != episodeUuid }
        let startIndex = episodeUuid.flatMap { uuid in episodes.firstIndex(where: { $0.uuid == uuid }).map { $0 + 1 } } ?? 0
        if startIndex < episodes.count, let next = episodes[startIndex...].first(where: isCandidate) {
            return next
        }
        return episodes.first(where: isCandidate)
    }

    func remainingCount(excluding episodeUuid: String?) -> Int {
        remainingEpisodes(excluding: episodeUuid).count
    }
}
