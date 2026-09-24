import Foundation
import PocketCastsDataModel
import PocketCastsUtils

// Fork: the missing half of podcast-settings sync. The base version ships the
// PodcastSettings model, the @ModifiedDate machinery and the full-sync apply
// path (processSettings) — but never converts the server's Api_PodcastSettings
// blob, so playback speed/effects/skips silently stayed behind when an account
// moved over from stock Pocket Casts. These conversions close the loop in both
// directions with the server's own per-field modified_at last-writer-wins.

extension PodcastSettings {
    /// Merges the server's settings blob into this instance: a server field wins
    /// only when its modified_at is newer than the local field's (a value changed
    /// on this device more recently keeps winning). Accepted fields carry no local
    /// modifiedAt afterwards, so merged-in values are never re-uploaded as ours.
    mutating func mergeLWW(api: Api_PodcastSettings) {
        $customEffects.update(setting: api.playbackEffects)
        $autoStartFrom.update(setting: api.autoStartFrom)
        $autoSkipLast.update(setting: api.autoSkipLast)
        $trimSilence.update(setting: api.trimSilence)
        $playbackSpeed.update(setting: api.playbackSpeed)
        $boostVolume.update(setting: api.volumeBoost)
        $notification.update(setting: api.notification)
        $autoArchive.update(setting: api.autoArchive)
        $autoArchivePlayed.update(setting: api.autoArchivePlayed)
        $autoArchiveInactive.update(setting: api.autoArchiveInactive)
        $autoArchiveEpisodeLimit.update(setting: api.autoArchiveEpisodeLimit)
        $addToUpNext.update(setting: api.addToUpNext)
        $addToUpNextPosition.update(setting: api.addToUpNextPosition)
        $episodesSortOrder.update(setting: api.episodesSortOrder)
        $episodeGrouping.update(setting: api.episodeGrouping)
        $showArchived.update(setting: api.showArchived)
    }

    /// The server blob converted standalone — used where a fresh account import
    /// has no local state to defend (defaults + LWW = the server's values).
    init(api: Api_PodcastSettings) {
        self = .defaults
        mergeLWW(api: api)
    }
}

extension Api_PodcastSettings {
    /// The outgoing blob: only fields actually changed on this device (those with
    /// a local modifiedAt) are included, stamped with when they changed — the
    /// server merges per field, so this can never clobber another device's newer
    /// change to a different field.
    init(from settings: PodcastSettings) {
        self.init()
        playbackEffects.update(settings.$customEffects)
        autoStartFrom.update(settings.$autoStartFrom)
        autoSkipLast.update(settings.$autoSkipLast)
        trimSilence.update(settings.$trimSilence)
        playbackSpeed.update(settings.$playbackSpeed)
        volumeBoost.update(settings.$boostVolume)
        notification.update(settings.$notification)
        autoArchive.update(settings.$autoArchive)
        autoArchivePlayed.update(settings.$autoArchivePlayed)
        autoArchiveInactive.update(settings.$autoArchiveInactive)
        autoArchiveEpisodeLimit.update(settings.$autoArchiveEpisodeLimit)
        addToUpNext.update(settings.$addToUpNext)
        addToUpNextPosition.update(settings.$addToUpNextPosition)
        episodesSortOrder.update(settings.$episodesSortOrder)
        episodeGrouping.update(settings.$episodeGrouping)
        showArchived.update(settings.$showArchived)
    }
}

extension Podcast {
    /// Copies setting changes a merge actually ACCEPTED into the legacy columns
    /// this app's UI and playback read. Deliberately per-field-on-change: a blob
    /// field that lost LWW (or was never set) must not stomp the legacy value.
    ///
    /// Scope: playback effects, skips and the notification toggle — the fields
    /// whose legacy columns are the app's source of truth today. Auto-archive,
    /// grouping, sort order and Up Next position are merged into `settings` (so
    /// they round-trip to other devices) but not mirrored: the fork's session
    /// engine owns queue behavior and their legacy semantics differ.
    func mirrorAcceptedSettings(from old: PodcastSettings) {
        if old.$customEffects != settings.$customEffects {
            overrideGlobalEffects = settings.customEffects
        }
        if old.$playbackSpeed != settings.$playbackSpeed {
            playbackSpeed = settings.playbackSpeed
        }
        if old.$trimSilence != settings.$trimSilence {
            trimSilenceAmount = settings.trimSilence.amount.rawValue
        }
        if old.$boostVolume != settings.$boostVolume {
            boostVolume = settings.boostVolume
        }
        if old.$autoStartFrom != settings.$autoStartFrom {
            startFrom = settings.autoStartFrom
        }
        if old.$autoSkipLast != settings.$autoSkipLast {
            skipLast = settings.autoSkipLast
        }
        if old.$notification != settings.$notification {
            pushEnabled = settings.notification
        }
    }
}
