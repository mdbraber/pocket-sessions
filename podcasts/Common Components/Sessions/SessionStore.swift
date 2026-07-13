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
    var insertMode: Int32 = PlaylistInsertMode.afterLastInserted.rawValue
    var lastInsertedUuid: String = ""
    var groupBy: Int = 0
    var groupLimit: Int = 0
    /// When the session was last the active playback session — the Switch Session
    /// sheet orders by it, latest first.
    var lastUsed: Date? = nil

    var id: String { uuid }
}

extension SessionFeeder {
    /// Stable per-inbox key for the seen watermark, independent of whether a real
    /// session row exists. Preview sessions share a constant uuid, so keying the
    /// watermark by the feeder keeps each podcast/playlist inbox's line distinct.
    var inboxKey: String {
        switch self {
        case .none: return "inbox-none"
        case .podcast(let uuid): return "inbox-podcast-\(uuid)"
        case .folder(let uuid): return "inbox-folder-\(uuid)"
        case .smartPlaylist(let uuid): return "inbox-smart-\(uuid)"
        case .allPodcasts: return SessionStore.globalInboxUuid
        }
    }
}

extension Session {
    /// The watermark key for this session's inbox — see `SessionFeeder.inboxKey`.
    var inboxKey: String { feeder.inboxKey }
}

/// A value snapshot of the session document, for cloud-sync diffing.
struct SessionStoreSnapshot {
    let sessions: [Session]
    let seenMarks: [String: Date]
    let unseenMarks: [String: Date]
    let clearedThrough: [String: Date]
    let dismissals: [String: [String: Date]]

    fileprivate init(document: SessionStore.Document) {
        sessions = document.sessions
        seenMarks = document.seenMarks
        unseenMarks = document.unseenMarks
        clearedThrough = document.clearedThrough
        dismissals = document.dismissals
    }
}

/// Fork: the single owner of all session-world local state — sessions, manual seen
/// marks, and per-session dismissals — persisted as one JSON document. Nothing in here
/// is (or may become) server-synced meaning; synced objects are referenced by uuid only.
final class SessionStore {
    static let shared = SessionStore()

    static let changed = NSNotification.Name(rawValue: "SJSessionsChanged")
    static let globalInboxUuid = "global-inbox"

    struct Document: Codable {
        var sessions: [Session] = []
        // Seen is a bounded hybrid: a per-inbox "cleared-through" watermark
        // (episodes published on/before it are seen in that inbox — the global
        // inbox's watermark is a floor across all inboxes) plus small per-episode
        // override sets for selectively marking individual episodes seen/unseen.
        var clearedThrough: [String: Date] = [:] // feederUuid -> watermark date
        var seenMarks: [String: Date] = [:] // episodeUuid -> date (explicit seen)
        var unseenMarks: [String: Date] = [:] // episodeUuid -> date (explicit unseen override)
        var dismissals: [String: [String: Date]] = [:] // sessionUuid -> episodeUuid -> date

        init() {}

        enum CodingKeys: String, CodingKey {
            case sessions, clearedThrough, seenMarks, unseenMarks, dismissals
        }

        // CRITICAL: decode every key with decodeIfPresent so a document written by an
        // older (or newer) build — missing some keys — still loads instead of throwing
        // and resetting the whole store to empty. Synthesized Decodable throws on any
        // missing key even when the property has a default; that once wiped sessions.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            clearedThrough = try c.decodeIfPresent([String: Date].self, forKey: .clearedThrough) ?? [:]
            seenMarks = try c.decodeIfPresent([String: Date].self, forKey: .seenMarks) ?? [:]
            unseenMarks = try c.decodeIfPresent([String: Date].self, forKey: .unseenMarks) ?? [:]
            dismissals = try c.decodeIfPresent([String: [String: Date]].self, forKey: .dismissals) ?? [:]
        }
    }

    private var document = Document()
    private let queue = DispatchQueue(label: "au.com.pocketcasts.sessionstore")
    private lazy var fileURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("sessions.json")
    }()

    init() {
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
        var session = Session(uuid: Self.globalInboxUuid, storePlaylistUuid: nil, feeder: .allPodcasts)
        session.groupBy = 1 // release date
        upsert(session)
        return session
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
        mutate { document in
            if let index = document.sessions.firstIndex(where: { $0.uuid == session.uuid }) {
                document.sessions[index] = session
            } else {
                document.sessions.append(session)
            }
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

    /// Removes the session row and its bookkeeping. The store playlist and any feeder
    /// playlist are the caller's to delete (they're real synced objects).
    func delete(sessionUuid: String) {
        mutate { document in
            document.sessions.removeAll { $0.uuid == sessionUuid }
            document.dismissals.removeValue(forKey: sessionUuid)
        }
    }

    // MARK: - Seen (per-inbox watermark + per-episode overrides)

    /// The inbox's "cleared-through" watermark: episodes published on/before it are
    /// seen in that inbox. The global inbox's watermark is a floor everywhere.
    func clearedThrough(feederUuid: String) -> Date? {
        queue.sync { document.clearedThrough[feederUuid] }
    }

    /// Combined watermark applying to an inbox: the later of its own line and the
    /// global inbox floor.
    func effectiveWatermark(feederUuid: String) -> Date? {
        queue.sync {
            let own = document.clearedThrough[feederUuid]
            let floor = document.clearedThrough[Self.globalInboxUuid]
            switch (own, floor) {
            case (let a?, let b?): return max(a, b)
            case (let a?, nil): return a
            case (nil, let b?): return b
            default: return nil
            }
        }
    }

    /// Advances an inbox's watermark (never retreats). Bulk "Mark All as Seen" — one
    /// timestamp instead of a marker per episode. Also clears now-redundant overrides.
    func clearThrough(feederUuid: String, date: Date, episodeUuids: [String]) {
        mutate { document in
            if let existing = document.clearedThrough[feederUuid], existing >= date {
                // keep the later line
            } else {
                document.clearedThrough[feederUuid] = date
            }
            // These episodes are now seen by the watermark — drop any explicit
            // unseen overrides, and explicit seen marks become redundant.
            for uuid in episodeUuids {
                document.unseenMarks[uuid] = nil
                document.seenMarks[uuid] = nil
            }
        }
    }

    func isSeenMarked(episodeUuid: String) -> Bool {
        queue.sync { document.seenMarks[episodeUuid] != nil }
    }

    func isUnseenMarked(episodeUuid: String) -> Bool {
        queue.sync { document.unseenMarks[episodeUuid] != nil }
    }

    func markSeen(episodeUuid: String) {
        markSeen(episodeUuids: [episodeUuid])
    }

    /// Explicit per-episode seen (selective "clear this one"). Batched.
    func markSeen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        mutate { document in
            for uuid in episodeUuids {
                document.seenMarks[uuid] = Date()
                document.unseenMarks[uuid] = nil
            }
        }
    }

    /// Explicit per-episode unseen override — brings an episode back into inboxes
    /// even when a watermark would otherwise hide it. Batched.
    func markUnseen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        mutate { document in
            for uuid in episodeUuids {
                document.unseenMarks[uuid] = Date()
                document.seenMarks[uuid] = nil
            }
        }
    }

    // Remote-apply setters (exact date, single field, no cross-clearing — the paired
    // change arrives as its own synced record). Callers wrap these in applyRemote.
    func applyRemoteSeenMark(episodeUuid: String, date: Date?) {
        mutate { $0.seenMarks[episodeUuid] = date }
    }

    func applyRemoteUnseenMark(episodeUuid: String, date: Date?) {
        mutate { $0.unseenMarks[episodeUuid] = date }
    }

    func applyRemoteWatermark(feederUuid: String, date: Date?) {
        mutate { $0.clearedThrough[feederUuid] = date }
    }

    // MARK: - Dismissals (scoped "not in this session")

    func isDismissed(episodeUuid: String, sessionUuid: String) -> Bool {
        queue.sync { document.dismissals[sessionUuid]?[episodeUuid] != nil }
    }

    func dismissedUuids(sessionUuid: String) -> [String] {
        queue.sync { document.dismissals[sessionUuid].map { Array($0.keys) } ?? [] }
    }

    /// Removes the episode's dismissals across every session — marking it unseen
    /// means "offer this again", everywhere.
    func clearDismissals(episodeUuid: String) {
        clearDismissals(episodeUuids: [episodeUuid])
    }

    /// Batch variant: one disk write and one change notification for the whole set.
    func clearDismissals(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        mutate { document in
            for (sessionUuid, dismissals) in document.dismissals {
                var dismissals = dismissals
                for uuid in episodeUuids {
                    dismissals[uuid] = nil
                }
                document.dismissals[sessionUuid] = dismissals.isEmpty ? nil : dismissals
            }
        }
    }

    func setDismissed(_ dismissed: Bool, episodeUuid: String, sessionUuid: String) {
        mutate { document in
            var sessionDismissals = document.dismissals[sessionUuid] ?? [:]
            sessionDismissals[episodeUuid] = dismissed ? Date() : nil
            document.dismissals[sessionUuid] = sessionDismissals.isEmpty ? nil : sessionDismissals
        }
    }

    func setDismissed(episodeUuids: [String], sessionUuid: String) {
        guard !episodeUuids.isEmpty else { return }
        mutate { document in
            var sessionDismissals = document.dismissals[sessionUuid] ?? [:]
            for uuid in episodeUuids {
                sessionDismissals[uuid] = Date()
            }
            document.dismissals[sessionUuid] = sessionDismissals
        }
    }

    // MARK: - Pruning

    /// Bookkeeping only matters inside the offer horizon: entries for episodes that are
    /// archived, played, or deleted answer questions nobody asks anymore.
    func prune() {
        mutate { document in
            // Played/archived/deleted episodes never appear in any inbox. NEVER prune
            // by age — lens inboxes are unwindowed, so an old override stays
            // load-bearing forever. The watermark bounds growth instead.
            let staleCheck: (String) -> Bool = { uuid in
                guard let episode = DataManager.sharedManager.findBaseEpisode(uuid: uuid) else { return true }
                if episode.played() { return true }
                if let episode = episode as? Episode, episode.archived { return true }
                return false
            }
            // A seen mark subsumed by the global watermark floor is redundant — the
            // bulk clear already makes the episode seen. This is what keeps the
            // per-episode override set from growing without bound.
            let globalFloor = document.clearedThrough[Self.globalInboxUuid]
            let subsumed: (String) -> Bool = { uuid in
                guard let floor = globalFloor,
                      let episode = DataManager.sharedManager.findEpisode(uuid: uuid),
                      let published = episode.publishedDate else { return false }
                return published <= floor
            }
            document.seenMarks = document.seenMarks.filter { !staleCheck($0.key) && !subsumed($0.key) }
            document.unseenMarks = document.unseenMarks.filter { !staleCheck($0.key) }
            // Dismissals ("removed from this session") grow one per explicit remove.
            // A dismissal for an episode already below that session's watermark is
            // redundant — the watermark hides it anyway — so bound them the same way.
            for (sessionUuid, entries) in document.dismissals {
                let sessionWatermark: Date? = {
                    let own = document.clearedThrough[sessionUuid]
                    switch (own, globalFloor) {
                    case (let a?, let b?): return max(a, b)
                    case (let a?, nil): return a
                    case (nil, let b?): return b
                    default: return nil
                    }
                }()
                let kept = entries.filter { uuid, _ in
                    if staleCheck(uuid) { return false }
                    if let wm = sessionWatermark,
                       let published = DataManager.sharedManager.findEpisode(uuid: uuid)?.publishedDate,
                       published <= wm { return false }
                    return true
                }
                document.dismissals[sessionUuid] = kept.isEmpty ? nil : kept
            }
        }
    }

    // MARK: - Persistence

    /// Cloud sync taps every mutation here: old and new snapshots, on the store
    /// queue. Nil when sync is off; remote applications don't echo back.
    var cloudDiffHandler: ((_ old: SessionStoreSnapshot, _ new: SessionStoreSnapshot) -> Void)?
    private var applyingRemote = false

    private func mutate(_ block: (inout Document) -> Void) {
        queue.sync {
            let old = document
            block(&document)
            save()
            if !applyingRemote, let handler = cloudDiffHandler {
                handler(SessionStoreSnapshot(document: old), SessionStoreSnapshot(document: document))
            }
        }
        NotificationCenter.postOnMainThread(notification: Self.changed)
    }

    /// Applies a remote change without echoing it back into the sync engine.
    func applyRemote(_ block: @escaping () -> Void) {
        applyingRemote = true
        block()
        applyingRemote = false
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let loaded = try? JSONDecoder().decode(Document.self, from: data) else { return }
            document = loaded
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
