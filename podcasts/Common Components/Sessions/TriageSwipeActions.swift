import UIKit
import PocketCastsDataModel
import SwipeCellKit

/// Fork: the one triage swipe vocabulary, used by every inbox surface.
/// Left: Add to Session · Play Next · Play Last. Right: Archive/Unarchive ·
/// Mark as (Un)Seen. All state-aware; seen wears the eye.
enum TriageSwipes {
    static func leftActions(for episode: BaseEpisode, addToSession: @escaping () -> Void) -> [SwipeAction] {
        let add = SwipeAction(style: .default, title: nil) { _, _ in
            addToSession()
        }
        add.image = sessionAddImage
        add.backgroundColor = SwipeActionsHelper.addToPlaylistSwipeBackground
        add.accessibilityLabel = L10n.playlistAddToLineup
        add.hidesWhenSelected = true

        // The now-playing episode gets no left remove — the right swipe already
        // carries the remove verb, and two removes on one row is one too many.
        if PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid) {
            return [add]
        }

        // State-aware, like the app-wide queue swipes: a queued episode offers
        // Remove from Up Next instead of Play Next / Play Last.
        if PlaybackManager.shared.inUpNext(episode: episode) {
            let removeFromUpNext = SwipeAction(style: .default, title: nil) { _, _ in
                SessionLinking.removeFromUpNextAskingSession(episode: episode)
            }
            removeFromUpNext.image = UIImage(named: "episode-removenext")
            removeFromUpNext.backgroundColor = ThemeColor.support05()
            removeFromUpNext.accessibilityLabel = L10n.removeFromUpNext
            removeFromUpNext.hidesWhenSelected = true
            return [add, removeFromUpNext]
        }

        let addTop = SwipeAction(style: .default, title: nil) { _, _ in
            PlaybackManager.shared.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: true, userInitiated: true)
                    SessionLinking.mirrorQueueAdd(episodes: [episode])
        }
        addTop.image = UIImage(named: "list_playnext")
        addTop.backgroundColor = ThemeColor.support04()
        addTop.accessibilityLabel = L10n.playNext
        addTop.hidesWhenSelected = true

        let addBottom = SwipeAction(style: .default, title: nil) { _, _ in
            PlaybackManager.shared.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: false, userInitiated: true)
                    SessionLinking.mirrorQueueAdd(episodes: [episode])
        }
        addBottom.image = UIImage(named: "list_playlast")
        addBottom.backgroundColor = ThemeColor.support03()
        addBottom.accessibilityLabel = L10n.playLast
        addBottom.hidesWhenSelected = true

        // Honor the user's primary queue-swipe preference, like the stock helper.
        if Settings.primaryUpNextSwipeAction() == .playNext {
            return [add, addTop, addBottom]
        } else {
            return [add, addBottom, addTop]
        }
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

    static func rightActions(for episode: BaseEpisode, reload: @escaping () -> Void) -> [SwipeAction] {
        var actions = [SwipeAction]()

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
        seen.backgroundColor = ThemeColor.support05()
        seen.accessibilityLabel = unseen ? L10n.episodeMarkSeen : L10n.episodeMarkUnseen
        seen.hidesWhenSelected = true
        return seen
    }

    /// The seen iconography, everywhere — red, with the icon showing the action:
    /// a crossed-out eye marks seen (the soft no); an open eye marks unseen again.
    static func seenImage(for episode: BaseEpisode) -> UIImage? {
        let unseen = InboxManager.shared.isUnseen(episodeUuid: episode.uuid)
        return UIImage(systemName: unseen ? "eye.slash" : "eye",
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
