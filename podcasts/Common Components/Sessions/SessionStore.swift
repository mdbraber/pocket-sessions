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

/// Fork: the single owner of all session-world local state — sessions, manual seen
/// marks, and per-session dismissals — persisted as one JSON document. Nothing in here
/// is (or may become) server-synced meaning; synced objects are referenced by uuid only.
final class SessionStore {
    static let shared = SessionStore()

    static let changed = NSNotification.Name(rawValue: "SJSessionsChanged")
    static let globalInboxUuid = "global-inbox"

    private struct Document: Codable {
        var sessions: [Session] = []
        var seen: [String: Date] = [:] // episodeUuid -> date marked
        var dismissals: [String: [String: Date]] = [:] // sessionUuid -> episodeUuid -> date
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

    // MARK: - Seen (manual marks; real progress counts as seen at the predicate level)

    func isManuallySeen(episodeUuid: String) -> Bool {
        queue.sync { document.seen[episodeUuid] != nil }
    }

    func setSeen(_ seen: Bool, episodeUuid: String) {
        setSeen(seen, episodeUuids: [episodeUuid])
    }

    /// Batch variant: one disk write and one change notification for the whole set.
    func setSeen(_ seen: Bool, episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        mutate { document in
            for uuid in episodeUuids {
                document.seen[uuid] = seen ? Date() : nil
            }
        }
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
    /// archived, played, or older than the window answer questions nobody asks anymore.
    func prune() {
        mutate { document in
            // Only marks that can never matter again go: played/archived episodes
            // don't appear in any inbox. NEVER prune by age — lens inboxes are
            // unwindowed, so an old episode's seen mark stays load-bearing forever.
            let staleCheck: (String) -> Bool = { uuid in
                guard let episode = DataManager.sharedManager.findBaseEpisode(uuid: uuid) else { return true }
                if episode.played() { return true }
                if let episode = episode as? Episode, episode.archived { return true }
                return false
            }
            document.seen = document.seen.filter { !staleCheck($0.key) }
            for (sessionUuid, entries) in document.dismissals {
                let kept = entries.filter { !staleCheck($0.key) }
                document.dismissals[sessionUuid] = kept.isEmpty ? nil : kept
            }
        }
    }

    // MARK: - Persistence

    private func mutate(_ block: (inout Document) -> Void) {
        queue.sync {
            block(&document)
            save()
        }
        NotificationCenter.postOnMainThread(notification: Self.changed)
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let loaded = try? JSONDecoder().decode(Document.self, from: data) else { return }
            document = loaded
        }
    }

    /// Called on the store queue.
    private func save() {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
