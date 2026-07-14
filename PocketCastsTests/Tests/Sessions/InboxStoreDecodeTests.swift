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
}
