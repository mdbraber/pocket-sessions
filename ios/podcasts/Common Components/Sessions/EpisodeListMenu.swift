import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: an episode list's Group By settings, stored per page. A session's Episodes list on the Queue
/// screen and on its own playlist page share one page uuid, so they group alike.
struct EpisodeListGrouping {
    let pageUuid: String

    var groupBy: EpisodeGroupBy {
        get { EpisodeGroupBy(rawValue: UserDefaults.standard.integer(forKey: "SJPlaylistGroupBy-\(pageUuid)")) ?? .none }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: "SJPlaylistGroupBy-\(pageUuid)") }
    }

    /// Episodes per group; 0 means no limit.
    var limit: Int {
        get { UserDefaults.standard.integer(forKey: "SJPlaylistGroupLimit-\(pageUuid)") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "SJPlaylistGroupLimit-\(pageUuid)") }
    }

    /// Reverses the order the groups appear in (items inside each group keep their sort).
    var reversed: Bool {
        get { UserDefaults.standard.bool(forKey: "SJPlaylistReverseGroup-\(pageUuid)") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "SJPlaylistReverseGroup-\(pageUuid)") }
    }

    var isActive: Bool { groupBy != .none || limit > 0 }
}

/// Fork: the rows of an episode list's ⋯ menu, shared by the playlist page and the Queue screen's
/// session lineup so the two menus stay identical. Each builder takes the host's reactions as
/// closures; the rows themselves (labels, icons, submenus) live only here.
enum EpisodeListMenu {
    static func chromecastAction(_ action: @escaping () -> Void) -> OptionAction {
        OptionAction(label: "Chromecast", icon: "nav_cast_off", action: action)
    }

    static func multiSelectAction(_ action: @escaping () -> Void) -> OptionAction {
        OptionAction(label: L10n.selectEpisodes, icon: "option-multiselect", action: action)
    }

    /// Presents the cast picker — what `PCViewController.castButtonTapped` does, for hosts that
    /// aren't one.
    static func presentCastPicker(from controller: UIViewController) {
        let navController = SJUIUtils.navController(for: CastToViewController())
        navController.modalPresentationStyle = .fullScreen
        controller.present(navController, animated: true)
    }

    /// Sort By for a BROWSED list (an Episodes tab): a sticky display order, per page.
    static func browseSortAction(pageUuid: String, themeOverride: Theme.ThemeType? = nil, onChange: @escaping () -> Void) -> OptionAction {
        let action = OptionAction(label: L10n.sortBy, secondaryLabel: TriageTabSort.order(pageUuid: pageUuid).title, icon: "podcastlist_sort") {}
        action.submenu = {
            let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase, themeOverride: themeOverride)
            let current = TriageTabSort.order(pageUuid: pageUuid)
            for option in EpisodeOrder.menuOrder {
                picker.addAction(action: OptionAction(label: option.title, selected: current == option) {
                    TriageTabSort.setOrder(option, pageUuid: pageUuid)
                    onChange()
                })
            }
            return picker
        }
        return action
    }

    /// Sort By for a SESSION lineup: a sticky order saved on the session (see `LineupSort`), or
    /// Manual. `current` nil = Manual.
    static func lineupSortAction(current: EpisodeOrder?, themeOverride: Theme.ThemeType? = nil, onSelect: @escaping (EpisodeOrder?) -> Void) -> OptionAction {
        let action = OptionAction(label: L10n.sortBy, secondaryLabel: current?.title ?? L10n.lineupSortManual, icon: "podcastlist_sort") {}
        action.submenu = { lineupSortPicker(current: current, themeOverride: themeOverride, onSelect: onSelect) }
        return action
    }

    /// Manual first — hand-ordering is the base state — then the sorts, each checked when in force.
    static func lineupSortPicker(current: EpisodeOrder?, themeOverride: Theme.ThemeType? = nil, onSelect: @escaping (EpisodeOrder?) -> Void) -> OptionsPicker {
        let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase, themeOverride: themeOverride)
        picker.addAction(action: OptionAction(label: L10n.lineupSortManual, selected: current == nil) { onSelect(nil) })
        for option in LineupReorder.options {
            picker.addAction(action: OptionAction(label: option.title, selected: current == option) { onSelect(option) })
        }
        return picker
    }

    /// "Reorder Episodes": puts a drag handle on every row (Done leaves). Moving one makes the lineup
    /// Manual, and a grouped lineup goes Manual on entry — the handles need a flat list.
    static func reorderEpisodesAction(_ action: @escaping () -> Void) -> OptionAction {
        OptionAction(label: L10n.lineupReorderEpisodes, icon: "line.3.horizontal", action: action)
    }

    /// A session lineup's rows: Sort By, Group By (its submenu also holds Reverse Group Order once
    /// grouped), and Reorder Episodes. Each arrangement change is saved on the session and sets its
    /// play order (see `LineupSort`); `onChange` repaints the host.
    static func addLineupArrangementActions(to optionsPicker: OptionsPicker, session: Session, themeOverride: Theme.ThemeType? = nil, onChange: @escaping () -> Void, onReorderEpisodes: @escaping () -> Void) {
        optionsPicker.addAction(action: lineupSortAction(current: LineupSort.order(of: session), themeOverride: themeOverride) { order in
            LineupSort.set(order, for: session)
            onChange()
        })

        let grouping = LineupSort.grouping(of: session)
        let groupAction = OptionAction(label: L10n.inboxGroupBy, secondaryLabel: grouping.title, icon: "option-group") {}
        groupAction.submenu = {
            let picker = OptionsPicker(title: L10n.inboxGroupBy.localizedUppercase, themeOverride: themeOverride)
            for option in EpisodeGroupBy.menuOrder {
                picker.addAction(action: OptionAction(label: option.title, selected: grouping == option) {
                    LineupSort.setGrouping(option, for: session)
                    onChange()
                })
            }
            if grouping != .none {
                let reversed = LineupSort.groupsReversed(of: session)
                picker.addSectionTitle("")
                picker.addAction(action: OptionAction(label: L10n.groupReverseOrder, selected: reversed) {
                    LineupSort.setGroupsReversed(!reversed, for: session)
                    onChange()
                })
            }
            return picker
        }
        optionsPicker.addAction(action: groupAction)

        optionsPicker.addAction(action: reorderEpisodesAction(onReorderEpisodes))
    }

    /// Reorder for a LINEUP with no session behind it (a plain manual playlist): one saved order,
    /// re-arranged once (nothing sticks), plus the way into hand-ordering.
    static func lineupReorderAction(themeOverride: Theme.ThemeType? = nil, onReorderEpisodes: @escaping () -> Void, onReorder: @escaping (EpisodeOrder) -> Void) -> OptionAction {
        let action = OptionAction(label: L10n.lineupReorder, icon: "podcastlist_sort") {}
        action.submenu = { lineupReorderPicker(themeOverride: themeOverride, onReorderEpisodes: onReorderEpisodes, onReorder: onReorder) }
        return action
    }

    /// The reorder picker: hand-ordering first (it's the base state everything else falls back to),
    /// then the one-shot arrangements. Nothing here carries a checkmark — none of it is a mode.
    static func lineupReorderPicker(themeOverride: Theme.ThemeType? = nil, onReorderEpisodes: @escaping () -> Void, onReorder: @escaping (EpisodeOrder) -> Void) -> OptionsPicker {
        let picker = OptionsPicker(title: L10n.lineupReorder.localizedUppercase, themeOverride: themeOverride)
        picker.addAction(action: OptionAction(label: L10n.lineupReorderEpisodes, icon: "line.3.horizontal", action: onReorderEpisodes))
        for option in LineupReorder.options {
            picker.addAction(action: OptionAction(label: option.title) { onReorder(option) })
        }
        return picker
    }

    /// Group By for a browsed list. Its submenu holds everything about groups: the grouping, then —
    /// once grouped — how many episodes each group shows and Reverse Group Order.
    static func addGroupByActions(to optionsPicker: OptionsPicker, grouping: EpisodeListGrouping, themeOverride: Theme.ThemeType? = nil, onChange: @escaping () -> Void) {
        let groupAction = OptionAction(label: L10n.inboxGroupBy, secondaryLabel: grouping.groupBy.title, icon: "option-group") {}
        groupAction.submenu = {
            let picker = OptionsPicker(title: L10n.inboxGroupBy.localizedUppercase, themeOverride: themeOverride)
            for option in EpisodeGroupBy.menuOrder {
                picker.addAction(action: OptionAction(label: option.title, selected: grouping.groupBy == option) {
                    grouping.groupBy = option
                    onChange()
                })
            }
            guard grouping.groupBy != .none else { return picker }

            picker.addSectionTitle(L10n.episodeGroupLimit.localizedUppercase)
            picker.addAction(action: OptionAction(label: L10n.off, selected: grouping.limit == 0) {
                grouping.limit = 0
                onChange()
            })
            for limit in EpisodeGrouper.limitOptions {
                picker.addAction(action: OptionAction(label: "\(limit)", selected: grouping.limit == limit) {
                    grouping.limit = limit
                    onChange()
                })
            }

            picker.addSectionTitle("")
            picker.addAction(action: OptionAction(label: L10n.groupReverseOrder, selected: grouping.reversed) {
                grouping.reversed.toggle()
                onChange()
            })
            return picker
        }
        optionsPicker.addAction(action: groupAction)
    }

    // MARK: - Download All

    /// Download All for the episodes on screen, with the confirm (and not-on-Wi-Fi) sheet. `episodes`
    /// is read when the submenu opens, so it reflects the list as it is then.
    static func downloadAllAction(themeOverride: Theme.ThemeType? = nil, episodes: @escaping () -> [BaseEpisode], onTap: @escaping () -> Void = {}) -> OptionAction {
        let action = OptionAction(label: L10n.downloadAll, icon: "filter_downloaded", action: onTap)
        action.submenu = { downloadAllPicker(themeOverride: themeOverride, episodes: episodes()) }
        return action
    }

    private static func downloadAllPicker(themeOverride: Theme.ThemeType?, episodes: [BaseEpisode]) -> OptionsPicker? {
        let downloadable = episodes.filter { !$0.downloaded(pathFinder: DownloadManager.shared) && !$0.downloading() && !$0.queued() }
        let downloadLimitExceeded = downloadable.count > Constants.Limits.maxBulkDownloads
        let batch = Array(downloadable.prefix(Constants.Limits.maxBulkDownloads))
        if batch.isEmpty { return nil }

        let downloadAction = OptionAction(label: L10n.downloadCountPrompt(batch.count), icon: nil) {
            start(batch, queueForLater: false)
        }

        let confirmPicker = OptionsPicker(title: nil, themeOverride: themeOverride)
        var warningMessage = downloadLimitExceeded ? L10n.bulkDownloadMax : ""

        if NetworkUtils.shared.isConnectedToUnexpensiveConnection() {
            confirmPicker.addDescriptiveActions(title: L10n.downloadAll, message: warningMessage, icon: "filter_downloaded", actions: [downloadAction])
        } else {
            downloadAction.destructive = true

            let queueAction = OptionAction(label: L10n.queueForLater, icon: nil) {
                start(batch, queueForLater: true)
            }

            if !Settings.mobileDataAllowed() {
                warningMessage = L10n.downloadDataWarningWithSettingsLink("pktc://settings/storage-and-data") + "\n" + warningMessage
            }

            confirmPicker.addAttributedDescriptiveActions(title: L10n.notOnWifi, message: warningMessage, icon: "option-alert", actions: [downloadAction, queueAction])
        }
        return confirmPicker
    }

    private static func start(_ episodes: [BaseEpisode], queueForLater: Bool) {
        let uuids = episodes.map(\.uuid)
        DispatchQueue.global().async {
            for uuid in uuids {
                if queueForLater {
                    DownloadManager.shared.queueForLaterDownload(episodeUuid: uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                } else {
                    DownloadManager.shared.addToQueue(episodeUuid: uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                }
            }
        }
    }
}
