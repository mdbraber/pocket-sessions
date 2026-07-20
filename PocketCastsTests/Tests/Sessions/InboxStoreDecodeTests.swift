import XCTest

@testable import podcasts

/// Decode-safety for `InboxStore`, to the same contract as `SessionStoreDecodeTests`.
///
/// This document matters more than its size suggests: lose `offeredThrough` and every podcast
/// reads as "never offered", which on the next drain means every episode is new. The store
/// resetting to empty is not a small bug, it is a flood.
final class InboxStoreDecodeTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-store-decode-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        super.tearDown()
    }

    private func write(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document).write(to: fileURL)
    }

    func testDocumentMissingItsOnlyKeyLoadsEmptyRatherThanThrowing() throws {
        try write([:])

        XCTAssertTrue(InboxStore(fileURL: fileURL).offeredThrough.isEmpty)
    }

    func testUnknownKeyFromANewerBuildIsIgnored() throws {
        try write(["offeredThrough": ["pod-1": 1_700_000_000.0], "somethingFromTheFuture": 42])

        let store = InboxStore(fileURL: fileURL)

        XCTAssertEqual(store.offeredThrough(podcastUuid: "pod-1"), Date(timeIntervalSinceReferenceDate: 1_700_000_000))
    }

    func testGarbageFileLeavesStoreEmpty() throws {
        try Data("this is not json".utf8).write(to: fileURL)

        XCTAssertTrue(InboxStore(fileURL: fileURL).offeredThrough.isEmpty)
    }

    func testMissingFileLeavesStoreEmpty() {
        XCTAssertTrue(InboxStore(fileURL: fileURL).offeredThrough.isEmpty)
    }

    func testRoundTrip() {
        let written = InboxStore(fileURL: fileURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        written.advanceOfferedThrough(["pod-1": date])

        XCTAssertEqual(InboxStore(fileURL: fileURL).offeredThrough(podcastUuid: "pod-1"), date)
    }

    // MARK: - The watermark is monotonic

    /// A lower value can only mean a stale device or a stale CloudKit record. Honouring it
    /// would re-offer episodes the user has already triaged away — the exact flood the
    /// watermark exists to prevent.
    func testOfferedThroughNeverRetreats() {
        let store = InboxStore(fileURL: fileURL)
        let newer = Date(timeIntervalSince1970: 2_000_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000_000)

        store.advanceOfferedThrough(["pod-1": newer])
        store.advanceOfferedThrough(["pod-1": older])

        XCTAssertEqual(store.offeredThrough(podcastUuid: "pod-1"), newer, "a stale write must not lower the line")
    }

    func testRemoteOfferedThroughAlsoNeverRetreats() {
        let store = InboxStore(fileURL: fileURL)
        let newer = Date(timeIntervalSince1970: 2_000_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000_000)

        store.advanceOfferedThrough(["pod-1": newer])
        store.applyRemoteOfferedThrough(podcastUuid: "pod-1", date: older)

        XCTAssertEqual(store.offeredThrough(podcastUuid: "pod-1"), newer, "a stale CloudKit record must not lower the line")
    }

    /// Unsubscribing forgets the podcast, so a re-subscribe draws a fresh line rather than
    /// replaying its history.
    func testForgetRemovesThePodcastEntirely() {
        let store = InboxStore(fileURL: fileURL)
        store.advanceOfferedThrough(["pod-1": Date()])

        store.forget(podcastUuid: "pod-1")

        XCTAssertNil(store.offeredThrough(podcastUuid: "pod-1"))
    }

    // MARK: - The seen-ledger

    /// The decode-safety contract extends to the ledger keys: a document written by a build
    /// before the ledger existed must load with its `offeredThrough` intact and an empty
    /// ledger — never throw (which `load()` would swallow, wiping the file on next save).
    func testDocumentWithoutLedgerKeysLoadsEmptyLedgerAndKeepsOfferedThrough() throws {
        try write(["offeredThrough": ["pod-1": 1_700_000_000.0]])

        let store = InboxStore(fileURL: fileURL)

        XCTAssertEqual(store.offeredThrough(podcastUuid: "pod-1"), Date(timeIntervalSinceReferenceDate: 1_700_000_000))
        XCTAssertTrue(store.seenUuids().isEmpty)
    }

    func testSeenLedgerRoundTrips() {
        let written = InboxStore(fileURL: fileURL)
        written.recordSeen(episodeUuids: ["seen-one"])
        written.recordSeen(episodeUuids: ["toggled"])
        written.recordUnseen(episodeUuids: ["toggled"])

        let reloaded = InboxStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.isSeen("seen-one"))
        XCTAssertFalse(reloaded.isSeen("toggled"), "an unseen override must survive a reload too")
        XCTAssertEqual(reloaded.seenUuids(), ["seen-one"])
    }

    /// THE flip-flop test. Mark seen on device A, mark unseen on device B, then A's (older)
    /// seen entry arrives over CloudKit: the union-max merge must keep the answer "not seen".
    /// If it didn't, the import filter would resurrect the tombstone and fight mark-unseen.
    func testAnOlderRemoteSeenEntryCannotOverrideMarkUnseen() {
        let store = InboxStore(fileURL: fileURL)
        let earlier = Date().addingTimeInterval(-3_600)

        store.recordUnseen(episodeUuids: ["put-back"])
        store.applyRemoteSeenLedger(InboxSeenLedgerPayload(seenAt: ["put-back": earlier], unseenAt: [:]))

        XCTAssertFalse(store.isSeen("put-back"), "the newer unseen decision must win the merge")
    }

    /// ...and the mirror image: a *newer* remote seen decision beats an older local unseen.
    /// Latest decision wins, whichever device made it.
    func testANewerRemoteSeenEntryOverridesAnOlderUnseen() {
        let store = InboxStore(fileURL: fileURL)

        store.recordUnseen(episodeUuids: ["reseen"])
        store.applyRemoteSeenLedger(InboxSeenLedgerPayload(seenAt: ["reseen": Date().addingTimeInterval(60)], unseenAt: [:]))

        XCTAssertTrue(store.isSeen("reseen"))
    }

    /// Merging is a per-uuid UNION: entries absent on one side survive. Absence must never
    /// read as deletion — an explicit unseen travels as an override entry, not as absence.
    func testRemoteLedgerMergeIsAUnionNotAReplace() {
        let store = InboxStore(fileURL: fileURL)
        store.recordSeen(episodeUuids: ["local-only"])

        store.applyRemoteSeenLedger(InboxSeenLedgerPayload(seenAt: ["remote-only": Date()], unseenAt: [:]))

        XCTAssertEqual(store.seenUuids(), ["local-only", "remote-only"])
    }

    func testPruneSeenDropsOnlyEntriesOlderThanTheCutoff() throws {
        // Written directly because both `recordSeen` and the remote merge (correctly) refuse
        // to take on entries that old — only a file from the past can contain them.
        let ancient = Date().addingTimeInterval(-InboxStore.seenRetention - 86_400)
        let recent = Date().addingTimeInterval(-86_400)
        try write([
            "seenAt": ["ancient": ancient.timeIntervalSinceReferenceDate, "recent": recent.timeIntervalSinceReferenceDate],
            "unseenAt": ["ancient-override": ancient.timeIntervalSinceReferenceDate],
        ])
        let store = InboxStore(fileURL: fileURL)

        store.pruneSeen(olderThan: Date().addingTimeInterval(-InboxStore.seenRetention))

        XCTAssertEqual(store.seenUuids(), ["recent"], "the ancient entries must be gone, the recent one kept")
        XCTAssertFalse(InboxStore(fileURL: fileURL).isSeen("ancient"), "…and the prune must persist")
    }
}
