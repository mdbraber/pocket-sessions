import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: Pocket Casts Sessions (PCS) server sync — `SessionCloudSync`'s sibling for the self-hosted
/// server (see SESSIONS_SERVER_PLAN.md; server repo: pocket-sessions-server). Same store
/// seams: local mutations arrive through the stores' `cloudDiffHandler`s and upload as
/// JSON records; remote changes fetch by cursor and land through the stores' `applyRemote*`
/// paths, which suppress re-enqueue. Active INSTEAD of the CloudKit engine whenever a
/// server URL is configured (Settings.sessionServerURL) — unlike CloudKit, this works in
/// the simulator and pushes between devices.
///
/// Wire format (JSON): records are {uuid, updatedAt(unix ms), payload(inline JSON), deleted};
/// the seen-ledger and offeredThrough travel as whole small documents. Merge semantics are
/// the server's job (LWW per record, union-newest ledger, monotonic watermarks) — the client
/// only ships state and applies what comes back. Applying our own echoes is deliberate and
/// harmless: every applyRemote path is idempotent.
final class SessionServerSync {
    private(set) static var shared: SessionServerSync?

    static func start() {
        guard shared == nil, let baseURL = Settings.sessionServerURL() else { return }
        shared = SessionServerSync(baseURL: baseURL)
        FileLog.shared.addMessage("SessionServerSync: active against \(baseURL.absoluteString)")
    }

    private let baseURL: URL
    private let queue = DispatchQueue(label: "au.com.pocketcasts.sessionserversync")
    private let session = URLSession(configuration: .ephemeral)

    // Pending upload state, coalesced on `queue` and flushed debounced.
    private var pendingSessions: [String: [String: Any]] = [:]
    private var pendingPresets: [String: [String: Any]] = [:]
    private var pendingOffered: [String: Int64] = [:]
    private var ledgerDirty = false
    private var flushWork: DispatchWorkItem?

    private var cursorKey: String { "SJSessionServerCursor-\(baseURL.host ?? "server")" }
    // Versioned like SessionCloudSync's bootstrap: bumping the constant re-uploads every
    // local record on next launch — the recovery lever for a wiped or diverged server.
    private var bootstrapKey: String { "SJSessionServerBootstrapVersion-\(baseURL.host ?? "server")" }
    private static let bootstrapVersion = 1

    private init(baseURL: URL) {
        self.baseURL = baseURL

        SessionStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueueSessionDiff(old: old, new: new)
        }
        InboxStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueueInboxDiff(old: old, new: new)
        }
        FilterPresetStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueuePresetDiff(old: old, new: new)
        }

        queue.async { [weak self] in
            self?.bootstrapIfNeeded()
            self?.registerDevice()
            self?.pushNotifyTogglesIfChanged()
            self?.fetch()
        }

        // Silent pushes need no user permission — register unconditionally so the
        // server can wake this device; the token arrives via the AppDelegate.
        // Push delivery to a foregrounded app is best-effort (and flaky on the
        // simulator), so a light poll keeps an open app mirroring within seconds —
        // the fetch is a no-op whenever the cursor hasn't moved.
        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.registerForRemoteNotifications()
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else { return }
                self?.queue.async { self?.fetch() }
            }
        }

        // Foreground → catch up; PC sync completed → nudge the server (wakes other
        // devices now; triggers the mirror pull in M2). podcastUpdated fires when a
        // notification toggle flips (among other changes) — re-report the toggle set.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pcSyncCompleted), name: ServerNotifications.syncCompleted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userSignedIn), name: .userSignedIn, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(podcastUpdated), name: Constants.Notifications.podcastUpdated, object: nil)
        // Follow-playback (opt-in): the session pointer and its playing episode
        // travel through the server so idle devices can follow along.
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStateChanged), name: Constants.Notifications.playbackSessionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStateChanged), name: Constants.Notifications.playbackTrackChanged, object: nil)
        // Pausing uploads the position to PC immediately (recordPlaybackPosition)
        // but fires no sync — nudge so other devices pull the fresh position and
        // their paused players seek to it (stock seekToFromSync handles the rest).
        NotificationCenter.default.addObserver(self, selector: #selector(playbackDidPause), name: Constants.Notifications.playbackPaused, object: nil)
    }

    @objc private func playbackDidPause() {
        // Give the position upload a beat to land before waking the others.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.postNudge() }
    }

    @objc private func playbackStateChanged() {
        // Snapshot a beat later: the notifications fire before audio actually rolls.
        //
        // Publishing used to require this device to be PLAYING, which meant switching session
        // while paused never reached anywhere else — the other devices kept whatever pointer they
        // last saw, forever. What actually has to be guarded against is a device claiming the
        // pointer from STALE state (a fresh launch, or a pointer it just adopted); a deliberate
        // change of session is not that. So publishing now follows the session CHANGING, and the
        // fingerprint check below still suppresses anything that isn't genuinely new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, Settings.sessionSyncPlayback() else { return }
            let session = Settings.playbackSession()
            let paused = Settings.playbackSessionPaused()
            // The leader episode is only meaningful while this device is actually sounding —
            // otherwise publish the session alone and let the follower pick its own head.
            let episodeUuid = (session != nil && !paused && PlaybackManager.shared.playing())
                ? PlaybackManager.shared.currentEpisode()?.uuid : nil
            queue.async { self.publishPlaybackPointer(session: session, episodeUuid: episodeUuid) }
        }
    }

    // MARK: - Follow playback (opt-in)

    /// What this device last published — publishing is suppressed while unchanged.
    private var playbackFingerprintKey: String { "SJSessionPlaybackFingerprint-\(baseURL.host ?? "server")" }
    private var playbackAppliedAtKey: String { "SJSessionPlaybackAppliedAt-\(baseURL.host ?? "server")" }

    /// Publishes this device's active session + playing episode. A cleared pointer
    /// publishes too — the leader moving to plain queue playback is state worth
    /// following. Only called with a snapshot taken while this device was playing.
    private func publishPlaybackPointer(session: PlaybackSession?, episodeUuid: String?) {
        var payload: [String: Any] = ["deviceId": Settings.sessionServerDeviceId()]
        if let session {
            payload["type"] = session.type.rawValue
            payload["uuid"] = session.uuid
            if let episodeUuid {
                payload["episodeUuid"] = episodeUuid
            }
        } else {
            payload["cleared"] = true
        }
        let fingerprint = "\(payload["type"] ?? "")|\(payload["uuid"] ?? "")|\(payload["episodeUuid"] ?? "")|\(payload["cleared"] ?? "")"
        guard fingerprint != UserDefaults.standard.string(forKey: playbackFingerprintKey) else { return }
        request(path: "/session/v1/changes", method: "POST",
                body: ["playback": ["updatedAt": Self.nowMs(), "payload": payload]]) { [weak self] result in
            guard case .success = result, let self else { return }
            UserDefaults.standard.set(fingerprint, forKey: self.playbackFingerprintKey)
            FileLog.shared.addMessage("SessionServerSync: published playback pointer \(fingerprint)")
        }
    }

    /// Publishes this device's CURRENT pointer. `force` clears the suppression fingerprint first,
    /// so an explicit Upload re-states the pointer even when it hasn't changed since last time.
    private func publishCurrentPointer(force: Bool) {
        guard Settings.sessionSyncPlayback() else { return }
        if force { UserDefaults.standard.removeObject(forKey: playbackFingerprintKey) }
        let session = Settings.playbackSession()
        let paused = Settings.playbackSessionPaused()
        let episodeUuid = (session != nil && !paused && PlaybackManager.shared.playing())
            ? PlaybackManager.shared.currentEpisode()?.uuid : nil
        publishPlaybackPointer(session: session, episodeUuid: episodeUuid)
    }

    /// Adopts a remote playback pointer: an idle device switches its active session
    /// AND primes the session's current episode as Now Playing (paused, position
    /// from PC's own sync) — the same path the app's own "play session" uses, just
    /// without audio. A device that is actively playing is never yanked; the
    /// publisher's playing() requirement means adopting can't echo anything back.
    private func applyRemotePlayback(_ playback: [String: Any]) {
        guard Settings.sessionSyncPlayback(),
              let updatedAt = (playback["updatedAt"] as? NSNumber)?.int64Value,
              let payload = playback["payload"] as? [String: Any],
              payload["deviceId"] as? String != Settings.sessionServerDeviceId() else { return }

        DispatchQueue.main.async {
            // Recorded only once we're actually allowed to act, so a pointer that
            // arrives mid-playback is retried on a later fetch instead of lost.
            guard !PlaybackManager.shared.playing(),
                  updatedAt > UserDefaults.standard.object(forKey: self.playbackAppliedAtKey) as? Int64 ?? 0 else { return }
            UserDefaults.standard.set(updatedAt, forKey: self.playbackAppliedAtKey)

            if payload["cleared"] as? Bool == true {
                guard Settings.playbackSession() != nil else { return }
                Settings.setPlaybackSession(nil)
                FileLog.shared.addMessage("SessionServerSync: adopted cleared playback pointer")
                return
            }
            guard let typeRaw = payload["type"] as? String,
                  let type = PlaybackSessionType(rawValue: typeRaw),
                  let uuid = payload["uuid"] as? String else { return }
            let session = PlaybackSession(type: type, uuid: uuid)
            let episodeUuid = payload["episodeUuid"] as? String ?? ""
            let alreadyFramed = Settings.playbackSession() == session
                && (episodeUuid.isEmpty || PlaybackManager.shared.currentEpisode()?.uuid == episodeUuid)
            guard !alreadyFramed else { return }
            PlaybackManager.shared.startPlaybackSession(session, autoPlay: false)
            FileLog.shared.addMessage("SessionServerSync: adopted playback pointer \(typeRaw)/\(uuid) (leader episode \(episodeUuid))")
        }
    }

    @objc private func podcastUpdated() {
        queue.async { [weak self] in self?.pushNotifyTogglesIfChanged() }
    }

    /// Reports this device's per-podcast notification toggles (Podcast.pushEnabled)
    /// so the server's episode watcher can alert on them — the fork's replacement
    /// for PC's server-side notification settings. Sends the full set, but only
    /// when it differs from what this device last reported.
    private var notifyTogglesKey: String { "SJSessionNotifyToggles-\(baseURL.host ?? "server")" }

    /// Fork: re-report after the GLOBAL "New Episodes" switch flips. Nothing else changes the
    /// per-podcast toggles, so without this the server would keep the stale switch until the next
    /// podcast edit.
    func notificationSettingsChanged() {
        queue.async { [weak self] in self?.pushNotifyTogglesIfChanged() }
    }

    private func pushNotifyTogglesIfChanged() {
        let uuids = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
            .filter { $0.pushEnabled }
            .map(\.uuid)
            .sorted()
        // The GLOBAL switch rides along. It used to be a local-only UserDefaults flag, so turning
        // "New Episodes" off never reached the server and the watcher kept alerting on every
        // podcast that was still individually enabled.
        let enabled = Settings.notificationsNewEpisodes
        let fingerprint = "\(enabled ? 1 : 0)|" + uuids.joined(separator: ",")
        guard fingerprint != UserDefaults.standard.string(forKey: notifyTogglesKey) else { return }
        request(path: "/session/v1/notify-podcasts", method: "POST", body: ["uuids": uuids, "enabled": enabled]) { [weak self] result in
            guard case .success = result, let self else { return }
            UserDefaults.standard.set(fingerprint, forKey: self.notifyTogglesKey)
            FileLog.shared.addMessage("SessionServerSync: reported \(uuids.count) notification toggles (new episodes: \(enabled))")
        }
    }

    /// Called from the AppDelegate when APNs hands over (a possibly new) device
    /// token; re-registers so the server's fan-out set stays current.
    func updateAPNSToken(_ token: String) {
        guard token != Settings.sessionAPNSToken() else { return }
        Settings.setSessionAPNSToken(token)
        queue.async { [weak self] in self?.registerDevice() }
    }

    /// A PCS silent push landed ("your data moved") — pull session changes now.
    func fetchFromPush() {
        queue.async { [weak self] in self?.fetch() }
    }

    private var lastKnownAccountKey: String { "SJSessionLastKnownAccount-\(baseURL.host ?? "server")" }

    @objc private func appDidBecomeActive() {
        pullIfAccountChanged()
        queue.async { [weak self] in self?.fetch() }
    }

    /// Fork: notice the signed-in account changing, whichever way it changed.
    ///
    /// The `.userSignedIn` notification is posted by some sign-in paths and not others, and none
    /// of them fire when an account changes while the app is closed. Comparing the account we last
    /// saw against the one signed in now catches every case, including a first launch after a
    /// sign-out/sign-in elsewhere.
    private func pullIfAccountChanged() {
        let current = ServerSettings.syncingEmail() ?? ""
        let previous = UserDefaults.standard.string(forKey: lastKnownAccountKey)
        guard previous != current else { return }
        UserDefaults.standard.set(current, forKey: lastKnownAccountKey)
        // Nothing was known before (a fresh install): an ordinary fetch is enough.
        guard let previous, !previous.isEmpty, !current.isEmpty else { return }
        FileLog.shared.addMessage("SessionServerSync: account changed (\(previous) -> \(current)) — replacing local data from the server")
        pullReplacingLocal()
    }

    /// Fork: signing in pulls, without waiting to be asked.
    ///
    /// Signing in can mean signing in as SOMEONE ELSE, and everything held locally then belongs to
    /// the previous account — so the server has to be consulted before any of it is trusted. When
    /// the account matches the one the server is linked to, an ordinary merge is enough. When it
    /// doesn't, local data isn't ours to merge and the server replaces it wholesale.
    @objc private func userSignedIn() {
        // Signing in as someone else means everything local belongs to the previous account, so
        // the server replaces it; signing back in as the same account just catches up. The
        // account comparison lives in `pullIfAccountChanged`, which also covers the sign-in paths
        // that never post this notification.
        pullIfAccountChanged()
        queue.async { [weak self] in self?.fetch() }
    }

    /// Set when a sync was nudge-triggered: that sync only PULLED remote changes,
    /// so announcing it would ping-pong nudges between devices forever.
    private var suppressNextNudge = false

    @objc private func pcSyncCompleted() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.suppressNextNudge {
                self.suppressNextNudge = false
                return
            }
            self.postNudge()
        }
    }

    // MARK: - Local → server (diffs, mirroring SessionCloudSync's enqueue rules)

    private func enqueueSessionDiff(old: SessionStoreSnapshot, new: SessionStoreSnapshot) {
        let now = Self.nowMs()
        let oldByUuid = Dictionary(old.sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        let newByUuid = Dictionary(new.sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        queue.async { [weak self] in
            guard let self else { return }
            for (uuid, session) in newByUuid where oldByUuid[uuid] != session {
                guard let payload = Self.jsonObject(session) else { continue }
                self.pendingSessions[uuid] = ["uuid": uuid, "updatedAt": now, "payload": payload]
            }
            for uuid in oldByUuid.keys where newByUuid[uuid] == nil {
                self.pendingSessions[uuid] = ["uuid": uuid, "updatedAt": now, "deleted": true]
            }
            self.scheduleFlush()
        }
    }

    private func enqueuePresetDiff(old: FilterPresetStoreSnapshot, new: FilterPresetStoreSnapshot) {
        let now = Self.nowMs()
        let oldByUuid = Dictionary(old.presets.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        let newByUuid = Dictionary(new.presets.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        queue.async { [weak self] in
            guard let self else { return }
            for (uuid, preset) in newByUuid where oldByUuid[uuid] != preset {
                guard let payload = Self.jsonObject(preset) else { continue }
                self.pendingPresets[uuid] = ["uuid": uuid, "updatedAt": now, "payload": payload]
            }
            for uuid in oldByUuid.keys where newByUuid[uuid] == nil {
                self.pendingPresets[uuid] = ["uuid": uuid, "updatedAt": now, "deleted": true]
            }
            self.scheduleFlush()
        }
    }

    private func enqueueInboxDiff(old: InboxStoreSnapshot, new: InboxStoreSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            for (uuid, date) in new.offeredThrough where old.offeredThrough[uuid] != date {
                self.pendingOffered[uuid] = Self.ms(date)
            }
            // Removed offeredThrough entries (unsubscribe) are not tombstoned server-side
            // yet — the monotonic watermark lingering there is harmless (M2 cleans up).
            if old.seenAt != new.seenAt || old.unseenAt != new.unseenAt {
                self.ledgerDirty = true
            }
            self.scheduleFlush()
        }
    }

    /// First run against a server: everything currently in the stores becomes pending.
    private func bootstrapIfNeeded() {
        guard UserDefaults.standard.integer(forKey: bootstrapKey) < Self.bootstrapVersion else { return }
        let now = Self.nowMs()
        for session in SessionStore.shared.snapshot.sessions {
            if let payload = Self.jsonObject(session) {
                pendingSessions[session.uuid] = ["uuid": session.uuid, "updatedAt": now, "payload": payload]
            }
        }
        for preset in FilterPresetStore.shared.snapshot.presets {
            if let payload = Self.jsonObject(preset) {
                pendingPresets[preset.uuid] = ["uuid": preset.uuid, "updatedAt": now, "payload": payload]
            }
        }
        let inbox = InboxStore.shared.snapshot
        for (uuid, date) in inbox.offeredThrough { pendingOffered[uuid] = Self.ms(date) }
        ledgerDirty = !inbox.seenAt.isEmpty || !inbox.unseenAt.isEmpty
        UserDefaults.standard.set(Self.bootstrapVersion, forKey: bootstrapKey)
        scheduleFlush()
    }

    private func scheduleFlush() {
        // Coalesce into the already-scheduled window rather than resetting it — a busy
        // stretch (launch sweeps, a PC sync) would otherwise postpone the flush forever.
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushWork = nil
            self?.flush()
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func flush(completion: ((Bool) -> Void)? = nil) {
        var body: [String: Any] = [:]
        if !pendingSessions.isEmpty { body["sessions"] = Array(pendingSessions.values) }
        if !pendingPresets.isEmpty { body["presets"] = Array(pendingPresets.values) }
        if !pendingOffered.isEmpty { body["offered"] = pendingOffered }
        if ledgerDirty {
            // Ship the retention-filtered ledger; the server unions it with what it holds.
            let ledger = InboxStore.shared.seenLedger
            body["seenLedger"] = [
                "seenAt": InboxStore.withinSeenRetention(ledger.seenAt).mapValues(Self.ms),
                "unseenAt": InboxStore.withinSeenRetention(ledger.unseenAt).mapValues(Self.ms)
            ]
        }
        guard !body.isEmpty else {
            fetch(completion: completion)
            return
        }

        let sent = (pendingSessions, pendingPresets, pendingOffered, ledgerDirty)
        pendingSessions = [:]; pendingPresets = [:]; pendingOffered = [:]; ledgerDirty = false

        request(path: "/session/v1/changes", method: "POST", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Converge: fetch from our cursor so anything that landed meanwhile
                // (other devices) applies too; our own echo is idempotent.
                self.fetch(completion: completion)
            case .failure(let error):
                FileLog.shared.addMessage("SessionServerSync: upload failed (\(error.localizedDescription)) — requeued")
                // Re-merge what we tried to send under anything newer that arrived since.
                self.pendingSessions.merge(sent.0) { newer, _ in newer }
                self.pendingPresets.merge(sent.1) { newer, _ in newer }
                self.pendingOffered.merge(sent.2) { newer, older in max(newer, older) }
                self.ledgerDirty = self.ledgerDirty || sent.3
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.scheduleFlush() }
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    // MARK: - Server → local

    func fetch(completion: ((Bool) -> Void)? = nil) {
        let since = UserDefaults.standard.integer(forKey: cursorKey)
        request(path: "/session/v1/changes?since=\(since)", method: "GET", body: nil) { [weak self] result in
            guard let self, case .success(let data) = result,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            self.apply(dict)
            DispatchQueue.main.async { completion?(true) }
        }
    }

    // MARK: - Manual sync (Settings → Synchronization)

    /// Flush anything pending immediately, then fetch — the "Sync Now" button.
    func syncNow(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushWork?.cancel()
            self.flushWork = nil
            self.flush(completion: completion)
        }
    }

    /// "This device wins": every local record re-uploads stamped NOW (winning LWW on the
    /// server and, transitively, on every other device), and server-only records are
    /// tombstoned — replace, not union.
    func pushReplacingServer(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.request(path: "/session/v1/changes?since=0", method: "GET", body: nil) { result in
                guard case .success(let data) = result,
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let now = Self.nowMs()
                let localSessions = SessionStore.shared.snapshot.sessions
                let localSessionUuids = Set(localSessions.map(\.uuid))
                for session in localSessions {
                    guard let payload = Self.jsonObject(session) else { continue }
                    self.pendingSessions[session.uuid] = ["uuid": session.uuid, "updatedAt": now, "payload": payload]
                }
                for record in dict["sessions"] as? [[String: Any]] ?? [] {
                    if let uuid = record["uuid"] as? String, !localSessionUuids.contains(uuid), record["deleted"] as? Bool != true {
                        self.pendingSessions[uuid] = ["uuid": uuid, "updatedAt": now, "deleted": true]
                    }
                }
                let localPresets = FilterPresetStore.shared.snapshot.presets
                let localPresetUuids = Set(localPresets.map(\.uuid))
                for preset in localPresets {
                    guard let payload = Self.jsonObject(preset) else { continue }
                    self.pendingPresets[preset.uuid] = ["uuid": preset.uuid, "updatedAt": now, "payload": payload]
                }
                for record in dict["presets"] as? [[String: Any]] ?? [] {
                    if let uuid = record["uuid"] as? String, !localPresetUuids.contains(uuid), record["deleted"] as? Bool != true {
                        self.pendingPresets[uuid] = ["uuid": uuid, "updatedAt": now, "deleted": true]
                    }
                }
                let inbox = InboxStore.shared.snapshot
                for (uuid, date) in inbox.offeredThrough { self.pendingOffered[uuid] = Self.ms(date) }
                self.ledgerDirty = true
                // "This device wins" has to include which session is current, or Upload moves the
                // sessions but leaves every other device pointing at whatever it had before.
                self.publishCurrentPointer(force: true)
                self.flush(completion: completion)
            }
        }
    }

    /// "Server wins": local records the server doesn't have are deleted through the NORMAL
    /// path (their tombstones and store-playlist deletions propagate, so other devices
    /// converge on the same state), pending local uploads are dropped, and the full server
    /// state applies on top.
    func pullReplacingLocal(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.request(path: "/session/v1/changes?since=0", method: "GET", body: nil) { result in
                guard case .success(let data) = result,
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                // Drop local divergence that was waiting to upload — the server's view wins.
                self.pendingSessions = [:]; self.pendingPresets = [:]; self.pendingOffered = [:]; self.ledgerDirty = false

                let liveServerSessions = Set((dict["sessions"] as? [[String: Any]] ?? [])
                    .filter { $0["deleted"] as? Bool != true }
                    .compactMap { $0["uuid"] as? String })
                for local in SessionStore.shared.snapshot.sessions
                where local.uuid != SessionStore.globalInboxUuid && !liveServerSessions.contains(local.uuid) {
                    SessionManager.shared.deleteSession(local)
                }
                let liveServerPresets = Set((dict["presets"] as? [[String: Any]] ?? [])
                    .filter { $0["deleted"] as? Bool != true }
                    .compactMap { $0["uuid"] as? String })
                for preset in FilterPresetStore.shared.snapshot.presets where !liveServerPresets.contains(preset.uuid) {
                    FilterPresetStore.shared.delete(uuid: preset.uuid)
                }

                // "Server wins" includes which session is current. Clearing the applied-at
                // watermark makes the pointer land even when this device has already seen that
                // timestamp — an explicit Download is a request for the server's state, not a
                // catch-up.
                UserDefaults.standard.removeObject(forKey: self.playbackAppliedAtKey)
                self.apply(dict)
                DispatchQueue.main.async { completion?(true) }
            }
        }
    }

    private func apply(_ dict: [String: Any]) {
        let sessionRecords = dict["sessions"] as? [[String: Any]] ?? []
        for record in sessionRecords {
            guard let uuid = record["uuid"] as? String else { continue }
            if record["deleted"] as? Bool == true {
                SessionStore.shared.applyRemoteDelete(sessionUuid: uuid)
            } else if let session: Session = Self.decode(record["payload"]) {
                SessionStore.shared.applyRemoteUpsert(session)
            }
        }
        // Two devices that diverged before ever sharing a server each hold their own record
        // for "the same" session (same podcast/lens, different uuid) — merge them now, with a
        // deterministic winner so every device converges without coordination.
        if !sessionRecords.isEmpty {
            SessionManager.shared.dedupeSessionsByIdentity()
        }
        for record in dict["presets"] as? [[String: Any]] ?? [] {
            guard let uuid = record["uuid"] as? String else { continue }
            FilterPresetStore.shared.applyRemote {
                if record["deleted"] as? Bool == true {
                    FilterPresetStore.shared.delete(uuid: uuid)
                } else if let preset: FilterPreset = Self.decode(record["payload"]) {
                    FilterPresetStore.shared.upsert(preset)
                }
            }
        }
        if let offered = dict["offered"] as? [String: Any] {
            InboxStore.shared.applyRemote {
                for (uuid, value) in offered {
                    guard let ms = value as? NSNumber else { continue }
                    InboxStore.shared.applyRemoteOfferedThrough(podcastUuid: uuid, date: Self.date(ms.int64Value))
                }
            }
        }
        if let ledger = dict["seenLedger"] as? [String: Any] {
            let seenAt = (ledger["seenAt"] as? [String: NSNumber] ?? [:]).mapValues { Self.date($0.int64Value) }
            let unseenAt = (ledger["unseenAt"] as? [String: NSNumber] ?? [:]).mapValues { Self.date($0.int64Value) }
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteSeenLedger(InboxSeenLedgerPayload(seenAt: seenAt, unseenAt: unseenAt))
            }
        }
        if let playback = dict["playback"] as? [String: Any] {
            applyRemotePlayback(playback)
        }
        if let nudge = dict["nudge"] as? [String: Any], let seq = (nudge["seq"] as? NSNumber)?.int64Value {
            applyNudge(seq: seq, deviceId: nudge["deviceId"] as? String ?? "")
        }
        if let cursor = dict["cursor"] as? NSNumber {
            UserDefaults.standard.set(cursor.int64Value, forKey: cursorKey)
        }
    }

    /// Another device put fresh data on PC (paused with a new position, finished a
    /// sync) — pull it, so progress and queue stay current even when the silent
    /// push didn't reach this foregrounded app and only the poll saw the nudge.
    private var nudgeSeqKey: String { "SJSessionNudgeSeq-\(baseURL.host ?? "server")" }

    private func applyNudge(seq: Int64, deviceId: String) {
        let last = UserDefaults.standard.object(forKey: nudgeSeqKey) as? Int64 ?? 0
        guard seq > last else { return }
        UserDefaults.standard.set(seq, forKey: nudgeSeqKey)
        // First observation only baselines; and our own nudges aren't news.
        guard last > 0, deviceId != Settings.sessionServerDeviceId() else { return }
        suppressNextNudge = true
        FileLog.shared.addMessage("SessionServerSync: nudge \(seq) from another device — refreshing PC data")
        // The main SyncTask (episode progress incl. seekToFromSync for the loaded
        // episode) only runs inside the refresh pipeline; forced, because a nudge
        // is an explicit "there IS fresh data" signal, not a speculative poll.
        DispatchQueue.main.async { RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: true) }
    }

    // MARK: - Pocket Casts account link (M2)

    /// Whether the server holds a PC link, and for which email.
    /// Fork: drops the server's link to the Pocket Casts account. The sessions and playlists it
    /// already holds are untouched — this only stops it talking to Pocket Casts on your behalf.
    func pcUnlink(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            self?.request(path: "/session/v1/pc-link", method: "DELETE", body: nil) { result in
                if case .success = result {
                    FileLog.shared.addMessage("SessionServerSync: unlinked the PC account")
                    DispatchQueue.main.async { completion(true) }
                } else {
                    DispatchQueue.main.async { completion(false) }
                }
            }
        }
    }

    func pcLinkStatus(completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            self?.request(path: "/session/v1/pc-link", method: "GET", body: nil) { result in
                guard case .success(let data) = result,
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    DispatchQueue.main.async { completion(false, nil) }
                    return
                }
                DispatchQueue.main.async { completion(dict["linked"] as? Bool ?? false, dict["email"] as? String) }
            }
        }
    }

    /// The full PC-identity enrollment against the configured server, engine-free on
    /// purpose so it can run the moment a server URL is saved (no relaunch needed):
    /// ask the server for a pairing code, approve it with this device's own Pocket
    /// Casts session, then have the server redeem it. The server answers with a
    /// PCS API token of our own (stored here) — no bootstrap token, no secrets sent.
    static func enroll(completion: @escaping (String?) -> Void) {
        guard let baseURL = Settings.sessionServerURL() else {
            completion(nil)
            return
        }
        FileLog.shared.addMessage("SessionServerSync: starting PC-identity enrollment")
        enrollRequest(baseURL: baseURL, path: "/session/v1/pc-link/start", body: [:]) { dict in
            guard let dict, let linkId = dict["linkId"] as? String, !linkId.isEmpty,
                  let userCode = dict["userCode"] as? String, !userCode.isEmpty else {
                FileLog.shared.addMessage("SessionServerSync: enrollment start failed")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            Task { @MainActor in
                do {
                    _ = try await ApiServerHandler.shared.deviceApproveRequest(userCode: userCode, approve: true)
                } catch {
                    FileLog.shared.addMessage("SessionServerSync: PC device approve failed: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                completeEnrollment(baseURL: baseURL, linkId: linkId, attemptsLeft: 5, completion: completion)
            }
        }
    }

    /// The server answers "pending" until PC has registered the approval — retry
    /// briefly. Success delivers the linked email and stores the issued PCS token.
    private static func completeEnrollment(baseURL: URL, linkId: String, attemptsLeft: Int, completion: @escaping (String?) -> Void) {
        enrollRequest(baseURL: baseURL, path: "/session/v1/pc-link/complete", body: ["linkId": linkId]) { dict in
            guard let dict else {
                FileLog.shared.addMessage("SessionServerSync: enrollment complete failed")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if dict["pending"] as? Bool == true {
                guard attemptsLeft > 1 else {
                    FileLog.shared.addMessage("SessionServerSync: enrollment still pending after retries")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    completeEnrollment(baseURL: baseURL, linkId: linkId, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
                return
            }
            DispatchQueue.main.async {
                if let token = dict["apiToken"] as? String, !token.isEmpty {
                    Settings.setSessionServerToken(token)
                    // The relay authenticates with this token, so it only becomes usable now.
                    PCAPIRelaySettings.apply()
                }
                completion(dict["linked"] as? Bool == true ? (dict["email"] as? String ?? "") : nil)
            }
        }
    }

    private static func enrollRequest(baseURL: URL, path: String, body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Settings.sessionServerDeviceId(), forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                  let data, let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(dict)
        }.resume()
    }

    // MARK: - Registration + nudge

    private func registerDevice() {
        // Dev-signed builds (Debug — both simulator and `make device`) get sandbox
        // APNs tokens; TestFlight/App Store builds would be production.
        #if DEBUG
        let apnsEnv = "sandbox"
        #else
        let apnsEnv = "production"
        #endif
        request(path: "/session/v1/devices", method: "POST",
                body: ["deviceId": Settings.sessionServerDeviceId(),
                       "apnsToken": Settings.sessionAPNSToken() ?? "",
                       "apnsEnv": apnsEnv]) { _ in }
    }

    private func postNudge() {
        request(path: "/session/v1/nudge", method: "POST", body: [:]) { _ in }
    }

    // MARK: - Plumbing

    private func request(path: String, method: String, body: [String: Any]?, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: path, relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Settings.sessionServerDeviceId(), forHTTPHeaderField: "X-Device-Id")
        if let token = Settings.sessionServerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                    completion(.failure(URLError(.badServerResponse)))
                    return
                }
                completion(.success(data ?? Data()))
            }
        }.resume()
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func decode<T: Decodable>(_ jsonObject: Any?) -> T? {
        guard let jsonObject, JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
