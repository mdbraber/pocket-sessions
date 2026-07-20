import Foundation
import PocketCastsUtils

/// A value snapshot of the inbox document, for cloud-sync diffing.
struct InboxStoreSnapshot {
    let offeredThrough: [String: Date]
    let seenAt: [String: Date]
    let unseenAt: [String: Date]

    fileprivate init(document: InboxStore.Document) {
        offeredThrough = document.offeredThrough
        seenAt = document.seenAt
        unseenAt = document.unseenAt
    }
}

/// The seen-ledger as it travels over CloudKit: one record, one JSON payload, both maps.
/// Decode follows the same decodeIfPresent safety contract as the store document — a payload
/// written by an older build (missing a key) must merge as "empty", never fail to decode.
struct InboxSeenLedgerPayload: Codable {
    var seenAt: [String: Date] = [:]
    var unseenAt: [String: Date] = [:]

    init(seenAt: [String: Date], unseenAt: [String: Date]) {
        self.seenAt = seenAt
        self.unseenAt = unseenAt
    }

    enum CodingKeys: String, CodingKey {
        case seenAt
        case unseenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenAt = try c.decodeIfPresent([String: Date].self, forKey: .seenAt) ?? [:]
        unseenAt = try c.decodeIfPresent([String: Date].self, forKey: .unseenAt) ?? [:]
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

    struct Document: Codable, Equatable {
        /// podcastUuid -> "everything published on or before this has been offered".
        var offeredThrough: [String: Date] = [:]

        /// episodeUuid -> when it was deliberately marked seen (removed from the Inbox).
        ///
        /// This is the **seen-ledger**: the tombstones playlist sync doesn't have. Playlist sync
        /// is last-writer-wins over the whole membership set, so a lagging device re-uploads
        /// stale membership and the import re-adds episodes this device already triaged away.
        /// The ledger records the triage itself, so the import can refuse the resurrection.
        var seenAt: [String: Date] = [:]

        /// episodeUuid -> when it was deliberately marked *unseen* again (put back).
        ///
        /// INVARIANT (why this can't flip-flop): both maps only ever grow per key — every merge,
        /// local or remote, is a per-key union taking the newer date — and seen-ness is the pure
        /// function `seenAt[u] > unseenAt[u]` (unseen wins a tie). Union-max is commutative,
        /// associative, and idempotent, so any two devices converge to the same maps and hence
        /// the same answer; a decision can only be overridden by a strictly *later* opposite
        /// decision. A plain "remove from seenAt on mark-unseen" could NOT say this: the other
        /// device's older seen entry would union straight back in and resurrect the tombstone.
        var unseenAt: [String: Date] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case offeredThrough
            case seenAt
            case unseenAt
        }

        // CRITICAL: decode every key with decodeIfPresent. Synthesized Decodable throws
        // keyNotFound on a missing key even when the property has a default, `load()` below
        // swallows the throw, and the first mutation then overwrites the file with an empty
        // document. That is how the session store got wiped once. See SessionStoreDecodeTests.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offeredThrough = try c.decodeIfPresent([String: Date].self, forKey: .offeredThrough) ?? [:]
            seenAt = try c.decodeIfPresent([String: Date].self, forKey: .seenAt) ?? [:]
            unseenAt = try c.decodeIfPresent([String: Date].self, forKey: .unseenAt) ?? [:]
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

    // MARK: - Seen-ledger

    /// How long a ledger entry lives. Long enough that no realistic device lag outlasts it,
    /// short enough to cap growth: the ledger only ever holds ~90 days of triage decisions,
    /// so the single CloudKit record stays a few tens of KB even at heavy listening rates.
    static let seenRetention: TimeInterval = 90 * 24 * 60 * 60

    /// Drops entries older than the retention window from a ledger map. Applied when pruning,
    /// when building the CloudKit record, and when merging a fetched one — filtering in all
    /// three places is what lets a pruned entry actually die instead of ping-ponging back in
    /// from a device (or a server record) that hasn't pruned yet.
    static func withinSeenRetention(_ map: [String: Date], now: Date = Date()) -> [String: Date] {
        let cutoff = now.addingTimeInterval(-seenRetention)
        return map.filter { $0.value >= cutoff }
    }

    /// Per-key union taking the newer date — the ledger's one and only merge rule.
    static func unionNewest(_ a: [String: Date], _ b: [String: Date]) -> [String: Date] {
        a.merging(b) { max($0, $1) }
    }

    var seenLedger: InboxSeenLedgerPayload {
        queue.sync { InboxSeenLedgerPayload(seenAt: document.seenAt, unseenAt: document.unseenAt) }
    }

    /// Records a deliberate removal from the Inbox. Stamped "now" — but never below an existing
    /// unseen override plus a tick, so a local decision always wins the merge even against a
    /// device whose clock ran fast (see the invariant on `Document.unseenAt`).
    func recordSeen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        let now = Date()
        mutate { document in
            for uuid in episodeUuids {
                var stamp = now
                if let opposing = document.unseenAt[uuid], opposing >= stamp {
                    stamp = opposing.addingTimeInterval(1)
                }
                if let existing = document.seenAt[uuid], existing >= stamp { continue }
                document.seenAt[uuid] = stamp
            }
        }
    }

    /// Records a deliberate return to the Inbox: the uuid leaves the effective ledger.
    ///
    /// The local `seenAt` entry is removed (mark-unseen removes it from the ledger), and the
    /// synced unseen override is stamped so another device's *older* seen entry cannot union
    /// the tombstone back in — that's the flip-flop this design exists to prevent.
    func recordUnseen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        let now = Date()
        mutate { document in
            for uuid in episodeUuids {
                var stamp = now
                if let opposing = document.seenAt[uuid], opposing >= stamp {
                    stamp = opposing.addingTimeInterval(1)
                }
                document.seenAt.removeValue(forKey: uuid)
                if let existing = document.unseenAt[uuid], existing >= stamp { continue }
                document.unseenAt[uuid] = stamp
            }
        }
    }

    /// Seen means: a seen mark exists and no unseen override is at least as new.
    func isSeen(_ uuid: String) -> Bool {
        queue.sync { Self.effectivelySeen(uuid: uuid, document: document) }
    }

    /// The effective ledger — every uuid whose latest decision was "seen".
    func seenUuids() -> Set<String> {
        queue.sync {
            Set(document.seenAt.keys.filter { Self.effectivelySeen(uuid: $0, document: document) })
        }
    }

    private static func effectivelySeen(uuid: String, document: Document) -> Bool {
        guard let seen = document.seenAt[uuid] else { return false }
        guard let unseen = document.unseenAt[uuid] else { return true }
        return seen > unseen // unseen wins a tie
    }

    /// Drops ledger entries (both maps) older than the given date. Called from the drain —
    /// see `InboxManager.drain` for why that hook.
    func pruneSeen(olderThan cutoff: Date) {
        mutate { document in
            document.seenAt = document.seenAt.filter { $0.value >= cutoff }
            document.unseenAt = document.unseenAt.filter { $0.value >= cutoff }
        }
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

    /// Merges a fetched seen-ledger: per-key UNION taking the newer date, never a wholesale
    /// replace — two devices' ledgers merge, and absence on one side must NOT delete (an
    /// explicit unseen travels as an `unseenAt` entry, not as absence). Entries beyond the
    /// retention window are dropped on the way in so a pruned entry can't resurrect.
    func applyRemoteSeenLedger(_ payload: InboxSeenLedgerPayload) {
        let remoteSeen = Self.withinSeenRetention(payload.seenAt)
        let remoteUnseen = Self.withinSeenRetention(payload.unseenAt)
        mutate { document in
            document.seenAt = Self.unionNewest(document.seenAt, remoteSeen)
            document.unseenAt = Self.unionNewest(document.unseenAt, remoteUnseen)
        }
    }

    // MARK: - Persistence

    private func mutate(_ block: (inout Document) -> Void) {
        // A no-op mutation saves nothing and notifies no one. This matters for the seen-ledger:
        // the sweep and remote merges routinely re-assert existing state, and echoing those as
        // "changes" would ping-pong saves between the store, the sweep, and CloudKit.
        let didChange: Bool = queue.sync {
            let old = document
            block(&document)
            guard document != old else { return false }
            save()
            if !applyingRemote, let handler = cloudDiffHandler {
                handler(InboxStoreSnapshot(document: old), InboxStoreSnapshot(document: document))
            }
            return true
        }
        guard didChange else { return }
        NotificationCenter.postChangedWithoutBlocking(Self.changed)
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
