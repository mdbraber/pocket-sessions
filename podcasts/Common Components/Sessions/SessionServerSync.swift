import Foundation
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
            self?.fetch()
        }

        // Foreground → catch up; PC sync completed → nudge the server (wakes other
        // devices now; triggers the mirror pull in M2).
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pcSyncCompleted), name: ServerNotifications.syncCompleted, object: nil)
    }

    @objc private func appDidBecomeActive() {
        queue.async { [weak self] in self?.fetch() }
    }

    @objc private func pcSyncCompleted() {
        queue.async { [weak self] in self?.postNudge() }
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
        if let cursor = dict["cursor"] as? NSNumber {
            UserDefaults.standard.set(cursor.int64Value, forKey: cursorKey)
        }
    }

    // MARK: - Pocket Casts account link (M2)

    /// Whether the server holds a PC link, and for which email.
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

    /// Hands the server this device's PC refresh token (never a password); the server
    /// validates it with a real exchange and becomes "another PC client" for the mirror.
    func linkPCAccount(refreshToken: String, accessToken: String, completion: @escaping (String?) -> Void) {
        FileLog.shared.addMessage("SessionServerSync: linking PC account (refresh: \(!refreshToken.isEmpty), access: \(!accessToken.isEmpty))")
        queue.async { [weak self] in
            self?.request(path: "/session/v1/pc-link", method: "POST",
                          body: ["refreshToken": refreshToken, "accessToken": accessToken]) { result in
                if case .failure(let error) = result {
                    FileLog.shared.addMessage("SessionServerSync: PC link failed: \(error.localizedDescription)")
                }
                guard case .success(let data) = result,
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.async { completion(dict["email"] as? String) }
            }
        }
    }

    // MARK: - Registration + nudge

    private func registerDevice() {
        // APNs token registration lands with the push milestone; the registration itself
        // already puts this device in the server's fan-out set for the log pusher.
        request(path: "/session/v1/devices", method: "POST",
                body: ["deviceId": Settings.sessionServerDeviceId(), "apnsToken": "", "apnsEnv": "sandbox"]) { _ in }
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
