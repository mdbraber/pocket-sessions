import Foundation
import PocketCastsUtils

/// A value snapshot of the inbox document, for cloud-sync diffing.
struct InboxStoreSnapshot {
    let offeredThrough: [String: Date]

    fileprivate init(document: InboxStore.Document) {
        offeredThrough = document.offeredThrough
    }
}

/// Fork: the Inbox's bookkeeping — and nothing else.
///
/// The Inbox itself is a manual playlist (membership means "unseen"); it syncs through
/// Pocket Casts' own playlist sync and needs no help from us. What this store holds is the
/// one thing that *cannot* live there: **`offeredThrough`**, a per-podcast date meaning
/// "every episode published on or before this has already been offered to the Inbox".
///
/// Why it has to exist. `Podcast.latestEpisodeUuid` — the cursor the refresh sends as
/// `last_episodes` — is **device-local and never synced**, and refresh runs *before* sync.
/// So a second device whose cursor is behind re-detects an episode the first device already
/// offered and the user already triaged away, and puts it back. Membership-as-state makes
/// that worse, because absence is ambiguous: "not in the Inbox" cannot distinguish "triaged
/// away" from "never offered". `offeredThrough` is what makes the answer unambiguous, and it
/// is race-free because `publishedDate` is server-consistent — both devices compute the same
/// answer from it.
///
/// It **must** sync (`SessionCloudSync` carries it), or none of the above works.
///
/// It is deliberately NOT in `SessionStore`: it is refresh bookkeeping for the Inbox, not
/// session state. One document per feature — the decode bug that once wiped every session
/// did so precisely *because* everything shared one document.
final class InboxStore {
    static let shared = InboxStore()

    static let changed = NSNotification.Name(rawValue: "SJInboxStoreChanged")

    struct Document: Codable {
        /// podcastUuid -> "everything published on or before this has been offered".
        var offeredThrough: [String: Date] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case offeredThrough
        }

        // CRITICAL: decode every key with decodeIfPresent. Synthesized Decodable throws
        // keyNotFound on a missing key even when the property has a default, `load()` below
        // swallows the throw, and the first mutation then overwrites the file with an empty
        // document. That is how the session store got wiped once. See SessionStoreDecodeTests.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offeredThrough = try c.decodeIfPresent([String: Date].self, forKey: .offeredThrough) ?? [:]
        }
    }

    private var document = Document()
    private let queue = DispatchQueue(label: "au.com.pocketcasts.inboxstore")
    private let fileURL: URL

    static var defaultFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("inbox.json")
    }

    /// `fileURL` is injectable so the decode-safety tests can point a store at a temp file.
    init(fileURL: URL = InboxStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - offeredThrough

    var offeredThrough: [String: Date] {
        queue.sync { document.offeredThrough }
    }

    func offeredThrough(podcastUuid: String) -> Date? {
        queue.sync { document.offeredThrough[podcastUuid] }
    }

    /// Advances the line for several podcasts at once — ONE write, ONE notification.
    ///
    /// The watermark is **monotonic**: it never retreats. A lower value can only mean a stale
    /// device or a stale CloudKit record, and honouring it would re-offer episodes the user
    /// has already triaged away — the exact flood this whole mechanism exists to prevent.
    func advanceOfferedThrough(_ dates: [String: Date]) {
        guard !dates.isEmpty else { return }
        mutate { document in
            for (podcastUuid, date) in dates {
                if let existing = document.offeredThrough[podcastUuid], existing >= date { continue }
                document.offeredThrough[podcastUuid] = date
            }
        }
    }

    /// Forgets a podcast — used when it is unsubscribed, so a later re-subscribe is treated
    /// as new (watermark to newest, nothing backfilled) rather than replaying its history.
    func forget(podcastUuid: String) {
        guard offeredThrough(podcastUuid: podcastUuid) != nil else { return }
        mutate { $0.offeredThrough.removeValue(forKey: podcastUuid) }
    }

    // MARK: - Cloud

    /// Cloud sync taps every mutation here: old and new snapshots, on the store queue.
    var cloudDiffHandler: ((_ old: InboxStoreSnapshot, _ new: InboxStoreSnapshot) -> Void)?
    private var applyingRemote = false

    var snapshot: InboxStoreSnapshot {
        queue.sync { InboxStoreSnapshot(document: document) }
    }

    /// Applies a remote change without echoing it back into the sync engine. Remote values
    /// go through the same monotonic rule — a stale record must never lower the line.
    func applyRemote(_ block: @escaping () -> Void) {
        applyingRemote = true
        block()
        applyingRemote = false
    }

    func applyRemoteOfferedThrough(podcastUuid: String, date: Date?) {
        guard let date else {
            mutate { $0.offeredThrough.removeValue(forKey: podcastUuid) }
            return
        }
        advanceOfferedThrough([podcastUuid: date])
    }

    // MARK: - Persistence

    private func mutate(_ block: (inout Document) -> Void) {
        queue.sync {
            let old = document
            block(&document)
            save()
            if !applyingRemote, let handler = cloudDiffHandler {
                handler(InboxStoreSnapshot(document: old), InboxStoreSnapshot(document: document))
            }
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

    private func save() {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
