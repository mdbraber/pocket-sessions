import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: the Episodes funnel's vocabulary — one option per state, organized into
/// axis blocks. Each option is a switch that starts ON (except Archived); turning
/// one OFF hides that state from the list.
enum EpisodeStateFilter: String, CaseIterable {
    case unarchived
    case archived
    case inSession
    case notInSession
    case unplayed
    case inProgress
    case played
    case downloaded
    case notDownloaded
    case starred
    case notStarred



    /// The filter sheet's layout: one block per axis — the smart playlist rules'
    /// vocabulary. A fully-ON block leaves its axis unconstrained.
    static var sheetSections: [(title: String?, options: [EpisodeStateFilter])] {
        [
            (L10n.archive, [.unarchived, .archived]),
            (L10n.episodeFilterSessionStatus, [.inSession, .notInSession]),
            (L10n.episodeFilterPlayingStatus, [.unplayed, .inProgress, .played]),
            (L10n.filterDownloadStatus, [.downloaded, .notDownloaded]),
            (L10n.episodeFilterStarredStatus, [.starred, .notStarred])
        ]
    }

    /// What the funnel sheet actually offers — the session axis only exists while
    /// sessions do. (The model keeps the full set so stored values stay stable.)
    static var visibleSheetSections: [(title: String?, options: [EpisodeStateFilter])] {
        guard !FeatureFlag.sessions.enabled else { return sheetSections }
        return sheetSections.filter { $0.options != [.inSession, .notInSession] }
    }

    var title: String {
        switch self {
        case .unarchived: return L10n.episodeFilterUnarchived
        case .archived: return L10n.podcastArchived
        case .inSession: return L10n.episodeFilterInSession
        case .notInSession: return L10n.episodeFilterNotInSession
        case .unplayed: return L10n.statusUnplayed
        case .inProgress: return L10n.inProgress
        case .played: return L10n.statusPlayed
        case .downloaded: return L10n.statusDownloaded
        case .notDownloaded: return L10n.statusNotDownloaded
        case .starred: return L10n.statusStarred
        case .notStarred: return L10n.statusNotStarred
        }
    }

    /// Whether the episode belongs to the selected view. Subsets are taken from the
    /// full set, so e.g. Played includes archived-played episodes. Session status is
    /// about the page's own session — pass its store members.
    func matches(_ episode: Episode, sessionMemberUuids: Set<String> = []) -> Bool {
        switch self {
        case .unarchived:
            return !episode.archived
        case .archived:
            return episode.archived
        case .inSession:
            return sessionMemberUuids.contains(episode.uuid)
        case .notInSession:
            return !sessionMemberUuids.contains(episode.uuid)
        case .unplayed:
            return !episode.played() && !episode.inProgress()
        case .inProgress:
            return episode.inProgress()
        case .played:
            return episode.played()
        case .downloaded:
            return episode.downloaded(pathFinder: DownloadManager.shared)
        case .notDownloaded:
            return !episode.downloaded(pathFinder: DownloadManager.shared)
        case .starred:
            return episode.keepEpisode
        case .notStarred:
            return !episode.keepEpisode
        }
    }
}

/// Fork: the funnel's combined state — every option is a switch that starts ON
/// (except Archived) and turning one OFF hides that state. Within a block the ON
/// options OR together; blocks AND together; a fully-ON block leaves its axis alone.
struct EpisodeStateFilterSet: Equatable {
    var enabled: Set<EpisodeStateFilter>

    static let allOptions: Set<EpisodeStateFilter> = Set(EpisodeStateFilter.sheetSections.flatMap(\.options))
    static let defaultEnabled: Set<EpisodeStateFilter> = allOptions.subtracting([.archived])

    /// One filter for the whole app — the funnel means the same thing on every
    /// podcast and playlist page.
    private static let globalKey = "SJEpisodesFilterOn"

    static var global: EpisodeStateFilterSet {
        forKey(globalKey)
    }

    func saveGlobal() {
        save(forKey: Self.globalKey)
    }

    static func forKey(_ key: String) -> EpisodeStateFilterSet {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return EpisodeStateFilterSet(enabled: defaultEnabled)
        }
        return EpisodeStateFilterSet(enabled: Set(stored.split(separator: ",").compactMap { EpisodeStateFilter(rawValue: String($0)) }))
    }

    func save(forKey key: String) {
        UserDefaults.standard.set(enabled.map(\.rawValue).sorted().joined(separator: ","), forKey: key)
    }

    /// The icon cue: lights only when something is actually hidden — both the
    /// default and the everything-on state read as calm.
    var showsActiveCue: Bool {
        enabled != Self.defaultEnabled && !isUnfiltered
    }

    var needsSessionContext: Bool {
        !(enabled.contains(.inSession) && enabled.contains(.notInSession))
    }

    /// True when nothing is filtered at all (every switch on).
    var isUnfiltered: Bool { enabled.isSuperset(of: Self.allOptions) }

    mutating func toggle(_ option: EpisodeStateFilter) {
        if enabled.contains(option) {
            enabled.remove(option)
        } else {
            enabled.insert(option)
        }
    }

    func matches(_ episode: Episode, sessionMemberUuids: Set<String> = []) -> Bool {
        for section in EpisodeStateFilter.sheetSections {
            // No sessions, no session axis — a stored In Session choice must not
            // silently hide everything.
            if !FeatureFlag.sessions.enabled, section.options == [.inSession, .notInSession] { continue }
            let on = section.options.filter { enabled.contains($0) }
            if on.count == section.options.count { continue }
            if !on.contains(where: { $0.matches(episode, sessionMemberUuids: sessionMemberUuids) }) {
                return false
            }
        }
        return true
    }
}
