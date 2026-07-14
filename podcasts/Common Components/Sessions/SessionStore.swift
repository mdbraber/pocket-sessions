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
    var insertMode: Int32 = PlaylistInsertMode.afterLastInserted.rawValue
    var lastInsertedUuid: String = ""
    /// When the session was last the active playback session — the Switch Session
    /// sheet orders by it, latest first.
    var lastUsed: Date? = nil

    var id: String { uuid }

    init(
        uuid: String,
        storePlaylistUuid: String? = nil,
        feeder: SessionFeeder,
        autoAdd: Bool = false,
        insertMode: Int32 = PlaylistInsertMode.afterLastInserted.rawValue,
        lastInsertedUuid: String = "",
        lastUsed: Date? = nil
    ) {
        self.uuid = uuid
        self.storePlaylistUuid = storePlaylistUuid
        self.feeder = feeder
        self.autoAdd = autoAdd
        self.insertMode = insertMode
        self.lastInsertedUuid = lastInsertedUuid
        self.lastUsed = lastUsed
    }

    enum CodingKeys: String, CodingKey {
        case uuid, storePlaylistUuid, feeder, autoAdd, insertMode, lastInsertedUuid, lastUsed
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
        insertMode = try c.decodeIfPresent(Int32.self, forKey: .insertMode) ?? PlaylistInsertMode.afterLastInserted.rawValue
        lastInsertedUuid = try c.decodeIfPresent(String.self, forKey: .lastInsertedUuid) ?? ""
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
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

    struct Document: Codable {
        var sessions: [Session] = []

        init() {}

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

    /// Removes the session row. The store playlist and any feeder playlist are the
    /// caller's to delete (they're real synced objects).
    func delete(sessionUuid: String) {
        mutate { document in
            document.sessions.removeAll { $0.uuid == sessionUuid }
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
