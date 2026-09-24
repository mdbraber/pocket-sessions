import Foundation

// Fork: write-through setters for the per-podcast settings that sync. The app's
// UI and playback read the legacy columns, but only the `settings` struct syncs
// (its @ModifiedDate stamps make a local change win last-writer-wins and travel
// to the server) — so every user-initiated change must land in BOTH. Callers use
// these instead of assigning the legacy columns directly.
public extension Podcast {
    func updatePlaybackSpeedSetting(_ speed: Double) {
        playbackSpeed = speed
        settings.playbackSpeed = speed
        markSettingsChanged()
    }

    func updateTrimSilenceSetting(_ amount: TrimSilenceAmount) {
        trimSilenceAmount = amount.rawValue
        settings.trimSilence = TrimSilence(amount: amount)
        markSettingsChanged()
    }

    func updateBoostVolumeSetting(_ enabled: Bool) {
        boostVolume = enabled
        settings.boostVolume = enabled
        markSettingsChanged()
    }

    func updateOverrideGlobalEffectsSetting(_ enabled: Bool) {
        overrideGlobalEffects = enabled
        settings.customEffects = enabled
        markSettingsChanged()
    }

    func updateStartFromSetting(_ seconds: Int32) {
        startFrom = seconds
        settings.autoStartFrom = seconds
        markSettingsChanged()
    }

    func updateSkipLastSetting(_ seconds: Int32) {
        skipLast = seconds
        settings.autoSkipLast = seconds
        markSettingsChanged()
    }

    func updateNotificationSetting(_ enabled: Bool) {
        pushEnabled = enabled
        settings.notification = enabled
        markSettingsChanged()
    }

    private func markSettingsChanged() {
        syncStatus = SyncStatus.notSynced.rawValue
    }
}
