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
    private static let bootstrappedKey = "SJSessionCloudSyncBootstrapped"

    private let zoneID = CKRecordZone.ID(zoneName: zoneName)
    private var engine: CKSyncEngine?

    static func start() {
        guard shared == nil else { return }
        // No entitlement (or no account) → containerIdentifier lookup/engine setup
        // throws at the CK layer; the catch keeps the app fully functional offline.
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

        bootstrapIfNeeded()
    }

    // MARK: - Record identity

    private func recordID(session uuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "session|\(uuid)", zoneID: zoneID)
    }

    private func recordID(offeredThrough podcastUuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "offered|\(podcastUuid)", zoneID: zoneID)
    }

    // MARK: - Local → cloud

    /// First run: everything currently in the store becomes a pending save.
    private func bootstrapIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bootstrappedKey), let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        let snapshot = SessionStore.shared.snapshot
        var pending = [CKSyncEngine.PendingRecordZoneChange]()
        for session in snapshot.sessions {
            pending.append(.saveRecord(recordID(session: session.uuid)))
        }
        for podcastUuid in InboxStore.shared.snapshot.offeredThrough.keys {
            pending.append(.saveRecord(recordID(offeredThrough: podcastUuid)))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        UserDefaults.standard.set(true, forKey: Self.bootstrappedKey)
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

        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Every local mutation lands here (on the store queue) as an old/new snapshot.
    private func enqueueDiff(old: SessionStoreSnapshot, new: SessionStoreSnapshot) {
        guard let engine else { return }
        var pending = [CKSyncEngine.PendingRecordZoneChange]()

        let oldSessions = Dictionary(uniqueKeysWithValues: old.sessions.map { ($0.uuid, $0) })
        let newSessions = Dictionary(uniqueKeysWithValues: new.sessions.map { ($0.uuid, $0) })
        for (uuid, session) in newSessions where oldSessions[uuid] != session {
            pending.append(.saveRecord(recordID(session: uuid)))
        }
        for uuid in oldSessions.keys where newSessions[uuid] == nil {
            pending.append(.deleteRecord(recordID(session: uuid)))
        }





        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Builds the current record for a pending ID — nil if the item vanished since.
    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        let parts = recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        let snapshot = SessionStore.shared.snapshot
        switch parts.first {
        case "session":
            guard parts.count == 2, let session = snapshot.sessions.first(where: { $0.uuid == parts[1] }),
                  let payload = try? JSONEncoder().encode(session) else { return nil }
            let record = CKRecord(recordType: "ForkSession", recordID: recordID)
            record["payload"] = payload as NSData
            return record
        case "offered":
            guard parts.count == 2, let date = InboxStore.shared.offeredThrough(podcastUuid: parts[1]) else { return nil }
            let record = CKRecord(recordType: "ForkOfferedThrough", recordID: recordID)
            record["date"] = date as NSDate
            return record
        default:
            return nil
        }
    }

    // MARK: - Cloud → local

    private func apply(record: CKRecord) {
        let parts = record.recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        SessionStore.shared.applyRemote {
            switch parts.first {
            case "session":
                guard let payload = record["payload"] as? Data,
                      let session = try? JSONDecoder().decode(Session.self, from: payload) else { return }
                SessionStore.shared.upsert(session)
            default:
                break
            }
        }

        if parts.first == "offered", parts.count == 2 {
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteOfferedThrough(podcastUuid: parts[1], date: record["date"] as? Date)
            }
        }
    }

    private func applyDeletion(recordID: CKRecord.ID) {
        let parts = recordID.recordName.split(separator: "|", maxSplits: 2).map(String.init)
        SessionStore.shared.applyRemote {
            switch parts.first {
            case "session":
                guard parts.count == 2 else { return }
                SessionStore.shared.delete(sessionUuid: parts[1])
            default:
                break
            }
        }

        if parts.first == "offered", parts.count == 2 {
            InboxStore.shared.applyRemote {
                InboxStore.shared.applyRemoteOfferedThrough(podcastUuid: parts[1], date: nil)
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
            for modification in changes.modifications {
                apply(record: modification.record)
            }
            for deletion in changes.deletions {
                applyDeletion(recordID: deletion.recordID)
            }
        case .sentRecordZoneChanges(let sent):
            for failed in sent.failedRecordSaves {
                // Server wins: the fetched copy arrives via fetchedRecordZoneChanges.
                FileLog.shared.addMessage("SessionCloudSync: save failed for \(failed.record.recordID.recordName): \(failed.error)")
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                UserDefaults.standard.set(false, forKey: Self.bootstrappedKey)
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
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            self?.record(for: recordID)
        }
    }
}
