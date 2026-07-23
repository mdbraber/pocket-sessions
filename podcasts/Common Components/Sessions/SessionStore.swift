import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: what feeds a session — candidates come from a podcast, a folder, a smart
/// playlist's rules, every followed podcast (the global Inbox), or nothing (a static
/// store). Descriptors reference stable synced uuids only.
enum SessionFeeder: Codable, Equatable {
    case none
    case podcast(uuid: String)
    case folder(uuid: String)
    case smartPlaylist(uuid: String)
    case allPodcasts

    /// A single podcast's own list — the surfaces that ignore a preset's podcast/folder scope.
    var isSinglePodcast: Bool {
        if case .podcast = self { return true }
        return false
    }
}

/// Fork: a Session — a thin local coordinator. The lineup itself lives in a synced
/// manual playlist (the store); this row carries the feeder, settings, and marker.
struct Session: Codable, Equatable, Identifiable {
    let uuid: String
    /// The manual playlist holding the lineup. Nil only for the global Inbox.
    var storePlaylistUuid: String?
    var feeder: SessionFeeder

    // Settings (defaults chosen at creation; all locally owned).
    var autoAdd: Bool = false
    /// Fill mode: true (Automatic) lets feeders gather covered episodes into the lineup;
    /// false (Manual) means episodes join ONLY via explicit user adds.
    var autoFill: Bool = true
    var insertMode: Int32 = PlaylistInsertMode.top.rawValue
    var lastInsertedUuid: String = ""
    /// When the session was last the active playback session — the Switch Session
    /// sheet orders by it, latest first.
    var lastUsed: Date? = nil
    /// Episodes the USER explicitly added to this lineup ("Add to Session" and friends).
    /// The feeder's prune (`reconcileStoreToFeeder`) never removes a pinned member —
    /// only gathered members stay prunable. Pins never outlive membership: leaving the
    /// lineup unpins, so a later re-gather behaves normally.
    var pinnedEpisodeUuids: [String] = []
    /// Fork: the user's manual position in the "recent/planned" session list. Synced (it rides
    /// the CloudKit Session record). `Int.max` = never placed → falls to the end, in creation order.
    var sortIndex = Int.max

    var id: String { uuid }

    init(
        uuid: String,
        storePlaylistUuid: String? = nil,
        feeder: SessionFeeder,
        autoAdd: Bool = false,
        autoFill: Bool = true,
        insertMode: Int32 = PlaylistInsertMode.top.rawValue,
        lastInsertedUuid: String = "",
        lastUsed: Date? = nil,
        pinnedEpisodeUuids: [String] = [],
        sortIndex: Int = Int.max
    ) {
        self.uuid = uuid
        self.storePlaylistUuid = storePlaylistUuid
        self.feeder = feeder
        self.autoAdd = autoAdd
        self.autoFill = autoFill
        self.insertMode = insertMode
        self.lastInsertedUuid = lastInsertedUuid
        self.lastUsed = lastUsed
        self.pinnedEpisodeUuids = pinnedEpisodeUuids
        self.sortIndex = sortIndex
    }

    enum CodingKeys: String, CodingKey {
        case uuid, storePlaylistUuid, feeder, autoAdd, autoFill, insertMode, lastInsertedUuid, lastUsed, pinnedEpisodeUuids, sortIndex
    }

    // CRITICAL: same rule as Document.init(from:) — decode every defaulted key with
    // decodeIfPresent. Synthesized Decodable does NOT fall back to a property's default
    // value; it throws keyNotFound. Document decodes [Session], and decodeIfPresent only
    // returns nil for an ABSENT key — a present-but-undecodable element rethrows. So a
    // single Session missing one key used to throw all the way out of Document.init,
    // where load()'s `try?` swallowed it and reset the whole store to empty. That is the
    // bug that once wiped every session. Only uuid and feeder are genuinely required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        feeder = try c.decode(SessionFeeder.self, forKey: .feeder)
        storePlaylistUuid = try c.decodeIfPresent(String.self, forKey: .storePlaylistUuid)
        autoAdd = try c.decodeIfPresent(Bool.self, forKey: .autoAdd) ?? false
        autoFill = try c.decodeIfPresent(Bool.self, forKey: .autoFill) ?? true
        insertMode = try c.decodeIfPresent(Int32.self, forKey: .insertMode) ?? PlaylistInsertMode.top.rawValue
        lastInsertedUuid = try c.decodeIfPresent(String.self, forKey: .lastInsertedUuid) ?? ""
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        pinnedEpisodeUuids = try c.decodeIfPresent([String].self, forKey: .pinnedEpisodeUuids) ?? []
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? Int.max
    }
}

/// Fork: decodes `T` if it can, and yields nil instead of throwing if it can't. Wrapping
/// array elements in this means ONE corrupt row drops ONE row — it can never propagate out
/// and take the whole document with it. Belt to `Session.init(from:)`'s braces: that keeps
/// *known* schema drift lossless; this bounds the blast radius of everything else.
struct LenientlyDecoded<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A value snapshot of the session document, for cloud-sync diffing.
struct SessionStoreSnapshot {
    let sessions: [Session]

    fileprivate init(document: SessionStore.Document) {
        sessions = document.sessions
    }
}

/// Fork: the single owner of all session-world local state — sessions, manual seen
/// marks, and per-session dismissals — persisted as one JSON document. Nothing in here
/// is (or may become) server-synced meaning; synced objects are referenced by uuid only.
final class SessionStore {
    static let shared = SessionStore()

    static let changed = NSNotification.Name(rawValue: "SJSessionsChanged")
    static let globalInboxUuid = "global-inbox"

    struct Document: Codable, Equatable {
        var sessions: [Session] = []

        init() {}

        /// Insert-or-replace a session by uuid, in place (document-level so it can run inside a single
        /// store-queue transaction — used by both local mutations and remote applies).
        mutating func upsertSession(_ session: Session) {
            if let index = sessions.firstIndex(where: { $0.uuid == session.uuid }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        }

        mutating func deleteSession(uuid: String) {
            sessions.removeAll { $0.uuid == uuid }
        }

        enum CodingKeys: String, CodingKey {
            case sessions
        }

        // CRITICAL: decode every key with decodeIfPresent so a document written by an
        // older (or newer) build — missing some keys — still loads instead of throwing
        // and resetting the whole store to empty. Synthesized Decodable throws on any
        // missing key even when the property has a default; that once wiped sessions.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Element-wise lenient: a single unreadable session drops that session, not the store.
            sessions = (try c.decodeIfPresent([LenientlyDecoded<Session>].self, forKey: .sessions) ?? [])
                .compactMap(\.value)
        }
    }

    private var document = Document()
    private let queue = DispatchQueue(label: "au.com.pocketcasts.sessionstore")
    private let fileURL: URL

    static var defaultFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("sessions.json")
    }

    /// `fileURL` is injectable so the decode-safety tests can point a store at a temp file.
    init(fileURL: URL = SessionStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Sessions

    var sessions: [Session] {
        queue.sync { document.sessions }
    }

    func session(uuid: String) -> Session? {
        queue.sync { document.sessions.first { $0.uuid == uuid } }
    }

    func session(forStore storePlaylistUuid: String) -> Session? {
        queue.sync { document.sessions.first { $0.storePlaylistUuid == storePlaylistUuid } }
    }

    func session(forFolder folderUuid: String) -> Session? {
        queue.sync {
            document.sessions.first {
                if case .folder(let uuid) = $0.feeder { return uuid == folderUuid }
                return false
            }
        }
    }

    func session(forPodcast podcastUuid: String) -> Session? {
        queue.sync {
            document.sessions.first {
                if case .podcast(let uuid) = $0.feeder { return uuid == podcastUuid }
                return false
            }
        }
    }

    var globalInbox: Session {
        if let existing = session(uuid: Self.globalInboxUuid) { return existing }
        let session = Session(uuid: Self.globalInboxUuid, storePlaylistUuid: nil, feeder: .allPodcasts)
        upsert(session)
        return session
    }

    /// Enforces the "exactly one Inbox" invariant: removes any `.allPodcasts` session whose uuid isn't
    /// the canonical `globalInboxUuid` — e.g. a legacy `fork-global-inbox-session` left in the synced
    /// document from before the Inbox was renamed. The Inbox has no store, so there's nothing else to
    /// clean up. No-op once none remain.
    func removeStrayInboxes() {
        let strays = sessions.filter {
            if case .allPodcasts = $0.feeder { return $0.uuid != Self.globalInboxUuid }
            return false
        }
        for stray in strays { delete(sessionUuid: stray.uuid) }
    }

    /// The smart playlist uuids acting as hidden feeders — filtered out of every
    /// fork-side playlist list. Only spawned "— feed" copies hide; a visible smart
    /// playlist feeding its own session stays where it is.
    var feederPlaylistUuids: Set<String> {
        let candidates: Set<String> = queue.sync {
            Set(document.sessions.compactMap {
                if case .smartPlaylist(let uuid) = $0.feeder { return uuid }
                return nil
            })
        }
        return Set(candidates.filter {
            DataManager.sharedManager.findPlaylist(uuid: $0)?.playlistName.hasSuffix(" — feed") ?? false
        })
    }

    func session(forSmartPlaylistFeeder playlistUuid: String) -> Session? {
        queue.sync {
            document.sessions.first {
                if case .smartPlaylist(let uuid) = $0.feeder { return uuid == playlistUuid }
                return false
            }
        }
    }

    func upsert(_ session: Session) {
        mutate { $0.upsertSession(session) }
    }

    /// Mutate a session in ONE transaction, starting from the LIVE stored row when present (falling
    /// back to the passed copy for a brand-new session). Re-reading inside the store queue means a
    /// stale captured `session` can't clobber fields another mutation changed concurrently (e.g.
    /// `lastUsed`, `sortIndex`), and lets a caller batch several field changes (lastInserted + pins)
    /// into a single save + cloud diff instead of a chain of `upsert`/`pin`/`unpin` calls.
    func mutateSession(_ session: Session, _ transform: (inout Session) -> Void) {
        mutate { document in
            var updated = document.sessions.first(where: { $0.uuid == session.uuid }) ?? session
            transform(&updated)
            document.upsertSession(updated)
        }
    }

    /// Stamps last-used for whichever session the playback-session uuid names (a
    /// store, a fed lens, or a podcast) — feeds the Switch Session sheet's recency
    /// ordering.
    func markUsed(playbackUuid: String) {
        guard var session = session(forStore: playbackUuid)
            ?? session(forSmartPlaylistFeeder: playbackUuid)
            ?? session(forPodcast: playbackUuid) else { return }
        session.lastUsed = Date()
        upsert(session)
    }

    /// Persists the fill mode for a session — Automatic (feeders gather covered
    /// episodes) vs Manual (episodes join only via explicit user adds).
    func setAutoFill(_ autoFill: Bool, for sessionUuid: String) {
        guard var session = session(uuid: sessionUuid), session.autoFill != autoFill else { return }
        session.autoFill = autoFill
        upsert(session)
    }

    /// Pins episodes in a session — a pin marks an explicit USER add, which the
    /// feeder's prune (`reconcileStoreToFeeder`) must never remove. No-op when every
    /// uuid is already pinned.
    func pin(episodeUuids: [String], for sessionUuid: String) {
        guard var session = session(uuid: sessionUuid) else { return }
        let toAdd = episodeUuids.filter { !session.pinnedEpisodeUuids.contains($0) }
        guard !toAdd.isEmpty else { return }
        session.pinnedEpisodeUuids.append(contentsOf: toAdd)
        upsert(session)
    }

    /// Unpins episodes — called whenever members leave a lineup, so pins never
    /// outlive membership and a later re-gather behaves normally. No-op when none
    /// of the uuids are pinned.
    func unpin(episodeUuids: [String], for sessionUuid: String) {
        guard var session = session(uuid: sessionUuid), !session.pinnedEpisodeUuids.isEmpty else { return }
        let remaining = session.pinnedEpisodeUuids.filter { !episodeUuids.contains($0) }
        guard remaining.count != session.pinnedEpisodeUuids.count else { return }
        session.pinnedEpisodeUuids = remaining
        upsert(session)
    }

    /// Removes the session row. The store playlist and any feeder playlist are the
    /// caller's to delete (they're real synced objects).
    func delete(sessionUuid: String) {
        mutate { $0.deleteSession(uuid: sessionUuid) }
    }

    /// Fork: the manual order for the "recent/planned" session list. Assigns each named session a
    /// `sortIndex` matching its position in `orderedUuids`; every other session keeps its own. The
    /// index rides the synced Session record, so the arrangement follows you across devices.
    func reorderSessions(_ orderedUuids: [String]) {
        // Build the uuid → offset map once (O(n)), then a single O(n) pass — not `firstIndex` inside
        // a loop over all uuids (which was O(n²) per drag/sort-apply).
        var offsets = [String: Int](minimumCapacity: orderedUuids.count)
        for (index, uuid) in orderedUuids.enumerated() { offsets[uuid] = index }
        mutate { document in
            for i in document.sessions.indices {
                guard let index = offsets[document.sessions[i].uuid],
                      document.sessions[i].sortIndex != index else { continue }
                document.sessions[i].sortIndex = index
            }
        }
    }


    // MARK: - Persistence

    /// Cloud sync taps every mutation here: old and new snapshots, on the store queue. Nil when sync
    /// is off; remote applies (see `applyRemoteUpsert`/`applyRemoteDelete`) never echo back.
    var cloudDiffHandler: ((_ old: SessionStoreSnapshot, _ new: SessionStoreSnapshot) -> Void)?

    /// A LOCAL mutation: persist + notify the cloud diff. Skips the file write, the cloud diff, and
    /// the change notification entirely when the block produced no change (many mutators are no-ops).
    private func mutate(_ block: (inout Document) -> Void) {
        let changed: Bool = queue.sync {
            let old = document
            block(&document)
            guard old != document else { return false }
            save()
            if let handler = cloudDiffHandler {
                handler(SessionStoreSnapshot(document: old), SessionStoreSnapshot(document: document))
            }
            return true
        }
        if changed { NotificationCenter.postChangedWithoutBlocking(Self.changed) }
    }

    /// A REMOTE apply: mutate + persist in a single queue-confined transaction, WITHOUT invoking the
    /// cloud diff (so it can't echo back to the sync engine). Replaces the old shared `applyingRemote`
    /// bool, which was written off-queue and could make a concurrent local mutation silently skip its
    /// own sync (a data race + lost-sync window).
    private func applyRemote(_ block: (inout Document) -> Void) {
        let changed: Bool = queue.sync {
            let old = document
            block(&document)
            guard old != document else { return false }
            save()
            return true
        }
        if changed { NotificationCenter.postChangedWithoutBlocking(Self.changed) }
    }

    func applyRemoteUpsert(_ session: Session) {
        applyRemote { $0.upsertSession(session) }
    }

    func applyRemoteDelete(sessionUuid: String) {
        applyRemote { $0.deleteSession(uuid: sessionUuid) }
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return } // no file yet — fresh store
            do {
                document = try JSONDecoder().decode(Document.self, from: data)
            } catch {
                // The file exists but won't decode (truncated / partial restore). Quarantine it before
                // the next mutation overwrites it with an empty document and loses everything.
                let quarantine = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? FileManager.default.removeItem(at: quarantine)
                try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            }
        }
    }

    /// The full current state, for the cloud sync's initial upload.
    var snapshot: SessionStoreSnapshot {
        queue.sync { SessionStoreSnapshot(document: document) }
    }

    /// Called on the store queue.
    private func save() {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension NotificationCenter {
    /// Posts a store-changed notification on the main thread WITHOUT ever blocking on it.
    /// The fork's document stores mutate during their own singleton init (e.g. seeding), and
    /// `postOnMainThread`'s off-main `DispatchQueue.main.sync` then deadlocks against any
    /// main-thread touch of the same `shared` static — a 0x8BADF00D watchdog kill. Observers
    /// of these notifications only refresh UI, so async delivery loses nothing.
    static func postChangedWithoutBlocking(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil) }
        }
    }
}
