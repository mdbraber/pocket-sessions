import UIKit
import PocketCastsDataModel
import SwipeCellKit

/// Fork: the one triage swipe vocabulary, used by every inbox surface.
/// Left: Add to Session (green) · Add to… (green, a picker). Right: Remove Session
/// (red) · Archive · Mark as (Un)Seen (blue). All state-aware.
enum TriageSwipes {
    /// Left swipe: Add to Session (green) — only when the episode is NOT in *this page's* session —
    /// then Add to… (the shared destination picker). (Remove from Session is the right
    /// swipe, shown when it IS.)
    static func leftActions(for episode: BaseEpisode,
                            inLocalSession: Bool,
                            presenting: UIViewController,
                            source: String = "swipe",
                            addToSession: @escaping () -> Void) -> [SwipeAction] {
        var leading = [SwipeAction]()
        if !inLocalSession {
            let add = SwipeAction(style: .default, title: nil) { _, _ in
                addToSession()
            }
            add.image = sessionAddImage
            add.backgroundColor = ThemeColor.support02() // session green
            add.accessibilityLabel = L10n.playlistAddToLineup
            add.hidesWhenSelected = true
            leading.append(add)
        }

        return leading + [addToAction(for: episode, presenting: presenting, source: source)]
    }

    /// "Add to…" — the shared second left-swipe action, everywhere. It never acts
    /// directly: it closes the swipe and asks where the episode should go (the top or
    /// the bottom of the Up Next queue, or a manual playlist).
    ///
    /// - Parameter onPlaylistChooser: overrides how the manual-playlist chooser is
    ///   opened (the Up Next screen has to dismiss itself first); by default the
    ///   standard `NavigationManager` route is used.
    static func addToAction(for episode: BaseEpisode,
                            presenting: UIViewController,
                            source: String = "swipe",
                            themeOverride: Theme.ThemeType? = nil,
                            onPlaylistChooser: (() -> Void)? = nil) -> SwipeAction {
        let uuid = episode.uuid
        let action = SwipeAction(style: .default, title: nil) { [weak presenting] action, _ in
            action.fulfill(with: .reset)
            guard let presenting else { return }
            presentAddToPicker(episodeUuid: uuid,
                               presenting: presenting,
                               source: source,
                               themeOverride: themeOverride,
                               onPlaylistChooser: onPlaylistChooser)
        }
        action.image = UIImage(named: "plus-circle")
        action.backgroundColor = ThemeColor.support02()
        action.accessibilityLabel = L10n.swipeAddTo
        action.hidesWhenSelected = true
        return action
    }

    private static func presentAddToPicker(episodeUuid uuid: String,
                                           presenting: UIViewController,
                                           source: String,
                                           themeOverride: Theme.ThemeType?,
                                           onPlaylistChooser: (() -> Void)?) {
        let picker = OptionsPicker(title: L10n.swipeAddToTitle.localizedUppercase, themeOverride: themeOverride)

        picker.addAction(action: OptionAction(label: L10n.addToUpNextTop, icon: "list_playnext") {
            guard let fresh = DataManager.sharedManager.findBaseEpisode(uuid: uuid) else { return }
            PlaybackManager.shared.addToUpNext(episode: fresh, ignoringQueueLimit: true, toTop: true, userInitiated: true)
            SessionLinking.mirrorQueueAdd(episodes: [fresh])
            Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_add_top", "source": source])
        })

        picker.addAction(action: OptionAction(label: L10n.addToUpNextBottom, icon: "list_playlast") {
            guard let fresh = DataManager.sharedManager.findBaseEpisode(uuid: uuid) else { return }
            PlaybackManager.shared.addToUpNext(episode: fresh, ignoringQueueLimit: true, toTop: false, userInitiated: true)
            SessionLinking.mirrorQueueAdd(episodes: [fresh])
            Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_add_bottom", "source": source])
        })

        // User episodes can't live in a manual playlist, so only offer it for podcast episodes.
        if DataManager.sharedManager.findEpisode(uuid: uuid) != nil {
            picker.addAction(action: OptionAction(label: L10n.playlistManualEpisodeAddToPlaylist, icon: "plus-circle") {
                if let onPlaylistChooser {
                    onPlaylistChooser()
                    return
                }
                guard let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) else { return }
                NavigationManager.sharedManager.navigateTo(
                    NavigationManager.manualPlaylistsChooserKey,
                    data: [
                        NavigationManager.manualPlaylistsChooserEpisodeKey: fresh
                    ]
                )
            })
        }

        picker.present(from: presenting)
    }

    /// The session glyph family (play.square.stack) with a plus: "add to the stack".
    static var sessionAddImage: UIImage? {
        sessionAddTemplateImage?.withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    /// Template variant for surfaces that tint themselves (settings rows).
    static var sessionAddTemplateImage: UIImage? {
        UIImage(systemName: "rectangle.stack.badge.plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
    }

    /// The remove counterpart: the session stack with an xmark badged top-right,
    /// knocked out with a ring of empty space (episode-removenext style). Template
    /// image — tint it per surface.
    static func sessionRemoveImage(pointSize: CGFloat = 17) -> UIImage? {
        let baseConfig = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        let xConfig = UIImage.SymbolConfiguration(pointSize: pointSize * 0.42, weight: .black)
        guard let base = UIImage(systemName: "rectangle.stack", withConfiguration: baseConfig),
              let xmark = UIImage(systemName: "xmark", withConfiguration: xConfig) else { return nil }

        let overhang = pointSize * 0.18
        let canvasSize = CGSize(width: base.size.width + overhang, height: base.size.height + overhang)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { context in
            base.withTintColor(.black).draw(at: CGPoint(x: 0, y: overhang))

            let xOrigin = CGPoint(x: canvasSize.width - xmark.size.width, y: 0)
            let xCenter = CGPoint(x: xOrigin.x + xmark.size.width / 2, y: xOrigin.y + xmark.size.height / 2)
            let radius = max(xmark.size.width, xmark.size.height) / 2 + pointSize * 0.14
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: xCenter.x - radius, y: xCenter.y - radius, width: radius * 2, height: radius * 2))
            context.cgContext.setBlendMode(.normal)
            xmark.withTintColor(.black).draw(at: xOrigin)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    static func rightActions(for episode: BaseEpisode, inLocalSession: Bool = false, removeFromSession: @escaping () -> Void = {}, reload: @escaping () -> Void) -> [SwipeAction] {
        var actions = [SwipeAction]()

        // Remove from Session (red) leads the trailing swipe when the episode is in this page's session.
        if inLocalSession {
            let remove = SwipeAction(style: .default, title: nil) { _, _ in
                removeFromSession()
            }
            remove.image = sessionRemoveImage()?.withTintColor(.white, renderingMode: .alwaysOriginal)
            remove.backgroundColor = ThemeColor.support05() // red
            remove.accessibilityLabel = L10n.sessionRemoveFrom
            remove.hidesWhenSelected = true
            actions.append(remove)
        }

        // Mutations always load a FRESH episode object: the table's cached one must
        // keep its old values so the diff-reload actually sees a change and redraws
        // the cell. fulfill(.reset) closes the swipe after a full-swipe expansion —
        // without it the cell hangs open when the row doesn't get deleted.
        if let episode = episode as? Episode {
            let uuid = episode.uuid
            if episode.archived {
                let unarchive = SwipeAction(style: .default, title: nil) { action, _ in
                    if let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) {
                        EpisodeManager.unarchiveEpisode(episode: fresh, fireNotification: true)
                    }
                    reload()
                    action.fulfill(with: .reset)
                }
                unarchive.image = UIImage(named: "list_unarchive")
                unarchive.backgroundColor = ThemeColor.support06()
                unarchive.accessibilityLabel = L10n.unarchive
                unarchive.hidesWhenSelected = true
                actions.append(unarchive)
            } else {
                let archive = SwipeAction(style: .default, title: nil) { action, _ in
                    if let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) {
                        EpisodeManager.archiveEpisode(episode: fresh, fireNotification: true)
                    }
                    reload()
                    action.fulfill(with: .reset)
                }
                archive.image = UIImage(named: "list_archive")
                archive.backgroundColor = ThemeColor.support06()
                archive.accessibilityLabel = L10n.archive
                archive.hidesWhenSelected = true
                actions.append(archive)
            }
        }

        actions.append(seenToggle(for: episode, reload: reload))
        return actions
    }

    static func seenToggle(for episode: BaseEpisode, reload: @escaping () -> Void) -> SwipeAction {
        let uuid = episode.uuid
        let unseen = InboxManager.shared.isUnseen(episodeUuid: uuid)
        let seen = SwipeAction(style: .default, title: nil) { action, _ in
            if unseen {
                InboxManager.shared.markSeen(episodeUuids: [uuid])
            } else {
                InboxManager.shared.markUnseen(episodeUuids: [uuid])
            }
            reload()
            action.fulfill(with: .reset)
        }
        seen.image = seenImage(for: episode)
        seen.backgroundColor = ThemeColor.support01() // blue, echoing the unread dot
        seen.accessibilityLabel = unseen ? L10n.episodeMarkSeen : L10n.episodeMarkUnseen
        seen.hidesWhenSelected = true
        return seen
    }

    /// The seen iconography, everywhere — blue, a circle echoing the unread dot: a filled circle when
    /// unseen (the dot you're clearing), a hollow one when seen (the dot you'd add back).
    static func seenImage(for episode: BaseEpisode) -> UIImage? {
        let unseen = InboxManager.shared.isUnseen(episodeUuid: episode.uuid)
        return UIImage(systemName: unseen ? "circle.fill" : "circle",
                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
    }
}

extension MultiSelectAction {
    /// The resolved icon: composed images first, then asset names, then SF symbols.
    /// Lives app-side — Enumerations.swift also compiles into the watch target.
    func iconImage() -> UIImage? {
        if self == .removeFromSession {
            return TriageSwipes.sessionRemoveImage(pointSize: 20)
        }
        return UIImage(named: iconName()) ?? UIImage(systemName: iconName())
    }
}
