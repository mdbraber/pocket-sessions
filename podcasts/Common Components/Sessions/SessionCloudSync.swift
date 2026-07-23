import CloudKit
import Foundation
import PocketCastsUtils

/// Fork: CloudKit sync for the session document — sessions, seen marks, and
/// dismissals as individual records in the private database, so merges are
/// per-record instead of whole-file clobbering. Lineups themselves already ride
/// Pocket Casts' own sync (they're manual playlists); this sidecar carries only
/// the fork's bookkeeping. Requires the iCloud/CloudKit entitlement — without it
/// (e.g. free-team signing) the engine fails quietly and the app runs local-only.
final class SessionCloudSync {
    private(set) static var shared: SessionCloudSync?

    private static let zoneName = "ForkSessions"
    private static let stateKey = "SJSessionCloudSyncState"
    // A bootstrap re-uploads every local record. Versioned so a fix that needs all devices to
    // re-sync (e.g. the serverRecordChanged etag fix) just bumps this constant — bootstrapIfNeeded
    // re-runs whenever the device's stored version is behind, no new key required. Devices that
    // diverged while saves were dropped reconcile to the union (each fetches the other's).
    // History: v1 = initial; v2 = serverRecordChanged etag fix.
    private static let bootstrapVersionKey = "SJSessionCloudSyncBootstrapVersion"
    private static let bootstrapVersion = 2

    private let zoneID = CKRecordZone.ID(zoneName: zoneName)
    private var engine: CKSyncEngine?

    /// Last-known server records (their system fields carry the change tag), keyed by ID. A save
    /// MUST start from this so it updates the existing record; a fresh, tag-less CKRecord is
    /// rejected as "record to insert already exists" (CKError.serverRecordChanged) once the record
    /// exists on the server, and the two devices never converge. Rebuilt from fetches, successful
    /// saves, and server records returned on a conflict — so it self-heals after a cold launch.
    private let cacheLock = NSLock()
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]

    private func baseRecord(for recordID: CKRecord.ID, type: String) -> CKRecord {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return serverRecords[recordID] ?? CKRecord(recordType: type, recordID: recordID)
    }

    private func rememberServerRecords(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        for record in records { serverRecords[record.recordID] = record }
    }

    private func forgetServerRecords(_ ids: [CKRecord.ID]) {
        guard !ids.isEmpty else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        for id in ids { serverRecords[id] = nil }
    }

    static func start() {
        guard shared == nil else { return }
        // CKContainer.default() TRAPS (EXC_BREAKPOINT, not a catchable exception) when the
        // build lacks the iCloud entitlement — e.g. the staging simulator app; only builds
        // signed with PocketCasts.device.entitlements carry it. The ubiquity token is the
        // public probe for exactly the safe case: non-nil only with iCloud entitlements AND
        // a signed-in account, the only situation CloudKit can actually sync in anyway.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            FileLog.shared.addMessage("SessionCloudSync: iCloud unavailable (no entitlement or not signed in) — running local-only")
            return
        }
        shared = SessionCloudSync()
    }

    private init() {
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer.default().privateCloudDatabase,
            stateSerialization: Self.loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)

        SessionStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueueDiff(old: old, new: new)
        }

        // Fork: `offeredThrough` MUST sync, or a second device re-offers episodes the first
        // has already triaged away. It lives in its own store, so it gets its own tap.
        InboxStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueueInboxDiff(old: old, new: new)
        }

        FilterPresetStore.shared.cloudDiffHandler = { [weak self] old, new in
            self?.enqueuePresetDiff(old: old, new: new)
        }

        bootstrapIfNeeded()
    }

    // MARK: - Record identity

    private func recordID(session uuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "session|\(uuid)", zoneID: zoneID)
    }

    private func recordID(offeredThrough podcastUuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "offered|\(podcastUuid)", zoneID: zoneID)
    }

    private func recordID(preset uuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "preset|\(uuid)", zoneID: zoneID)
    }

    /// The Inbox seen-ledger travels as ONE record holding the JSON-encoded maps, not a record
    /// per episode. The 90-day prune caps it at a few thousand entries (~tens of KB — far under
    /// the 1MB record limit), and one record means one union-merge on every apply instead of
    /// thousands of per-episode records churning through the engine. Per-podcast records exist
    /// for `offeredThrough` because each key there merges on its own monotonic rule; the ledger
    /// merges as a single union, so a single record is the natural grain.
    private var seenLedgerRecordID: CKRecord.ID {
        CKRecord.ID(recordName: "seenledger", zoneID: zoneID)
    }

    // MARK: - Local → cloud

    /// First run: everything currently in the store becomes a pending save.
    private func bootstrapIfNeeded() {
        guard UserDefaults.standard.integer(forKey: Self.bootstrapVersionKey) < Self.bootstrapVersion, let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        let snapshot = SessionStore.shared.snapshot
        var pending = [CKSyncEngine.PendingRecordZoneChange]()
        for session in snapshot.sessions {
            pending.append(.saveRecord(recordID(session: session.uuid)))
        }
        let inboxSnapshot = InboxStore.shared.snapshot
        for podcastUuid in inboxSnapshot.offeredThrough.keys {
            pending.append(.saveRecord(recordID(offeredThrough: podcastUuid)))
        }
        if !inboxSnapshot.seenAt.isEmpty || !inboxSnapshot.unseenAt.isEmpty {
            pending.append(.saveRecord(seenLedgerRecordID))
        }
        for preset in FilterPresetStore.shared.snapshot.presets {
            pending.append(.saveRecord(recordID(preset: preset.uuid)))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        UserDefaults.standard.set(Self.bootstrapVersion, forKey: Self.bootstrapVersionKey)
    }

    /// Every local `InboxStore` mutation lands here as an old/new snapshot.
    private func enqueueInboxDiff(old: InboxStoreSnapshot, new: InboxStoreSnapshot) {
        guard let engine else { return }
        var pending = [CKSyncEngine.PendingRecordZoneChange]()

        for uuid in new.offeredThrough.keys where old.offeredThrough[uuid] != new.offeredThrough[uuid] {
            pending.append(.saveRecord(recordID(offeredThrough: uuid)))
        }
        for uuid in old.offeredThrough.keys where new.offeredThrough[uuid] == nil {
            pending.append(.deleteRecord(recordID(offeredThrough: uuid)))
        }

        // The seen-ledger: any change to either map re-saves the single ledger record. Note
        // there is deliberately no `.deleteRecord` path — entries leave the ledger by the
        // record being re-saved without them (prune) or by an unseen override, never by
        // record deletion, because absence must not read as "delete" on the other side.
        if old.seenAt != new.seenAt || old.unseenAt != new.unseenAt {
            pending.append(.saveRecord(seenLedgerRecordID))
        }

        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Every local mutation lands here (on the store queue) as an old/new snapshot.
    private func enqueueDiff(old: SessionStoreSnapshot, new: SessionStoreSnapshot) {
        guard let engine else { return }
        var pending = [CKSyncEngine.PendingRecordZoneChange]()

        // `uniquingKeysWith` (not `uniqueKeysWithValues`) so a corrupt/merged document with a duplicate
        // uuid can't trap the whole diff.
        let oldSessions = Dictionary(old.sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        let newSessions = Dictionary(new.sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        for (uuid, session) in newSessions where oldSessions[uuid] != session {
            pending.append(.saveRecord(recordID(session: uuid)))
        }
        for uuid in oldSessions.keys where newSessions[uuid] == nil {
            pending.append(.deleteRecord(recordID(session: uuid)))
        }





        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Every local `FilterPresetStore` mutation lands here as an old/new snapshot.
    private func enqueuePresetDiff(old: FilterPresetStoreSnapshot, new: FilterPresetStoreSnapshot) {
        guard let engine else { return }
        var pending = [CKSyncEngine.PendingRecordZoneChange]()

        let oldPresets = Dictionary(old.presets.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        let newPresets = Dictionary(new.presets.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        for (uuid, preset) in newPresets where oldPresets[uuid] != preset {
            pending.append(.saveRecord(recordID(preset: uuid)))
        }
        for uuid in oldPresets.keys where newPresets[uuid] == nil {
            pending.append(.deleteRecord(recordID(preset: uuid)))
        }

        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Builds the current record for a pending ID — nil if the item vanished since. `sessionsByUuid`
    /// is a snapshot indexed ONCE per batch, so a reorder that dirties N session records doesn't
    /// re-snapshot + linear-scan the whole store per record (which was O(N²) per sync).
    private func record(for recordID: CKRecord.ID, sessionsByUuid: [String: Session]) -> CKRecord? {
        let parts = recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        switch parts.first {
        case "session":
            guard parts.count == 2, let session = sessionsByUuid[parts[1]],
                  let payload = try? JSONEncoder().encode(session) else { return nil }
            let record = baseRecord(for: recordID, type: "ForkSession")
            record["payload"] = payload as NSData
            return record
        case "offered":
            guard parts.count == 2, let date = InboxStore.shared.offeredThrough(podcastUuid: parts[1]) else { return nil }
            let record = baseRecord(for: recordID, type: "ForkOfferedThrough")
            // Never regress the triage watermark below what the server already holds — a lower date
            // would re-offer episodes the other device already triaged away.
            let serverDate = record["date"] as? Date
            record["date"] = (serverDate.map { max($0, date) } ?? date) as NSDate
            return record
        case "seenledger":
            // Write the UNION of our ledger and whatever the server record already holds —
            // never our maps alone. Record-level saves are last-writer-wins, so writing only
            // the local view would clobber entries a device with a newer server copy has that
            // we haven't fetched yet (the conflict-retry path hands us exactly that record).
            // Retention-filtering the result is what lets pruned entries actually die instead
            // of ping-ponging back from an unpruned server copy.
            let local = InboxStore.shared.seenLedger
            var seenAt = local.seenAt
            var unseenAt = local.unseenAt
            let record = baseRecord(for: recordID, type: "ForkInboxSeenLedger")
            if let serverData = record["payload"] as? Data,
               let serverLedger = try? JSONDecoder().decode(InboxSeenLedgerPayload.self, from: serverData) {
                seenAt = InboxStore.unionNewest(seenAt, serverLedger.seenAt)
                unseenAt = InboxStore.unionNewest(unseenAt, serverLedger.unseenAt)
            }
            let merged = InboxSeenLedgerPayload(
                seenAt: InboxStore.withinSeenRetention(seenAt),
                unseenAt: InboxStore.withinSeenRetention(unseenAt)
            )
            guard let payload = try? JSONEncoder().encode(merged) else { return nil }
            record["payload"] = payload as NSData
            return record
        case "preset":
            guard parts.count == 2, let preset = FilterPresetStore.shared.preset(uuid: parts[1]),
                  let payload = try? JSONEncoder().encode(preset) else { return nil }
            let record = baseRecord(for: recordID, type: "ForkFilterPreset")
            record["payload"] = payload as NSData
            return record
        default:
            return nil
        }
    }

    // MARK: - Cloud → local

    private func apply(record: CKRecord) {
        let parts = record.recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.first == "session",
           let payload = record["payload"] as? Data,
           let session = try? JSONDecoder().decode(Session.self, from: payload) {
            SessionStore.shared.applyRemoteUpsert(session)
        }

        if parts.first == "offered", parts.count == 2 {
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteOfferedThrough(podcastUuid: parts[1], date: record["date"] as? Date)
            }
        }

        if parts.first == "seenledger",
           let payload = record["payload"] as? Data,
           let ledger = try? JSONDecoder().decode(InboxSeenLedgerPayload.self, from: payload) {
            // Union-merge, never replace — see InboxStore.applyRemoteSeenLedger.
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteSeenLedger(ledger)
            }
        }

        if parts.first == "preset", parts.count == 2,
           let payload = record["payload"] as? Data,
           let preset = try? JSONDecoder().decode(FilterPreset.self, from: payload) {
            FilterPresetStore.shared.applyRemote {
                FilterPresetStore.shared.upsert(preset)
            }
        }
    }

    private func applyDeletion(recordID: CKRecord.ID) {
        let parts = recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.first == "session", parts.count == 2 {
            SessionStore.shared.applyRemoteDelete(sessionUuid: parts[1])
        }

        if parts.first == "offered", parts.count == 2 {
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteOfferedThrough(podcastUuid: parts[1], date: nil)
            }
        }

        // "seenledger" deliberately has no deletion handling: nothing in the app ever deletes
        // the record, and a stray deletion (dashboard cleanup, say) must not erase local
        // tombstones — the next local mutation simply re-saves the record.

        if parts.first == "preset", parts.count == 2 {
            FilterPresetStore.shared.applyRemote {
                FilterPresetStore.shared.delete(uuid: parts[1])
            }
        }
    }

    // MARK: - State persistence

    private static func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persist(state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}

extension SessionCloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persist(state: update.stateSerialization)
        case .fetchedRecordZoneChanges(let changes):
            rememberServerRecords(changes.modifications.map(\.record))
            forgetServerRecords(changes.deletions.map(\.recordID))
            for modification in changes.modifications {
                apply(record: modification.record)
            }
            for deletion in changes.deletions {
                applyDeletion(recordID: deletion.recordID)
            }
        case .sentRecordZoneChanges(let sent):
            rememberServerRecords(sent.savedRecords)
            forgetServerRecords(sent.deletedRecordIDs)
            var retry = [CKSyncEngine.PendingRecordZoneChange]()
            for failed in sent.failedRecordSaves {
                if failed.error.code == .serverRecordChanged, let serverRecord = failed.error.serverRecord {
                    // The record already exists on the server. Adopt its change tag, then re-save our
                    // value on top (last write wins) — otherwise the save is dropped forever and the
                    // devices never converge.
                    rememberServerRecords([serverRecord])
                    retry.append(.saveRecord(failed.record.recordID))
                } else {
                    FileLog.shared.addMessage("SessionCloudSync: save failed for \(failed.record.recordID.recordName): \(failed.error)")
                }
            }
            if !retry.isEmpty, let engine {
                engine.state.add(pendingRecordZoneChanges: retry)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                UserDefaults.standard.set(0, forKey: Self.bootstrapVersionKey)
                bootstrapIfNeeded()
            default:
                break
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // Snapshot + index the sessions ONCE for the whole batch (see `record(for:sessionsByUuid:)`).
        let sessionsByUuid = Dictionary(SessionStore.shared.snapshot.sessions.map { ($0.uuid, $0) },
                                        uniquingKeysWith: { _, last in last })
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            self?.record(for: recordID, sessionsByUuid: sessionsByUuid)
        }
    }
}
