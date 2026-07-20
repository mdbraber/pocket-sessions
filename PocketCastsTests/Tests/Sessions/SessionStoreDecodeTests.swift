import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Decode-safety characterisation tests for `SessionStore`.
///
/// These pin the one failure mode that has actually destroyed user data in this fork: a
/// JSON document that a build cannot fully decode gets swallowed by `load()`'s `try?`,
/// leaves the in-memory document empty, and is then overwritten by the first mutation.
///
/// The rule they enforce: **a document we can only partially understand must lose only the
/// part we could not understand — never more.** Add a key to `Session` and forget its
/// `decodeIfPresent`, and `testSessionMissingDefaultedKeysDecodesWithDefaults` fails loudly
/// instead of silently eating every session on the next launch.
final class SessionStoreDecodeTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-decode-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document).write(to: fileURL)
    }

    /// Round-trips a `Session` through the real encoder, so the tests never hand-guess the
    /// wire shape of `SessionFeeder` (a synthesized enum encoding).
    private func json(for session: Session) throws -> [String: Any] {
        let data = try JSONEncoder().encode(session)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Document level

    /// A document written before a top-level key existed must still load.
    func testDocumentMissingTopLevelKeysKeepsSessions() throws {
        let session = Session(uuid: "s1", storePlaylistUuid: "store-1", feeder: .podcast(uuid: "p1"))
        try write(["sessions": [json(for: session)]]) // no seenMarks/unseenMarks/clearedThrough/dismissals

        let store = SessionStore(fileURL: fileURL)

        XCTAssertEqual(store.sessions.map(\.uuid), ["s1"])
    }

    /// An entirely empty document must load as empty, not throw.
    func testEmptyDocumentLoadsEmpty() throws {
        try write([:])

        XCTAssertTrue(SessionStore(fileURL: fileURL).sessions.isEmpty)
    }

    // MARK: - Element level — this is the bug that wiped the store

    /// `Session` has defaulted, non-optional properties. Swift's *synthesized* `Decodable`
    /// does not fall back to a default value — it throws `keyNotFound`. Because `Document`
    /// decodes `[Session]`, and `decodeIfPresent` only returns nil for an ABSENT key (a
    /// present-but-undecodable value rethrows), one such session used to throw all the way
    /// out of `Document.init(from:)` and reset the whole store.
    func testSessionMissingDefaultedKeysDecodesWithDefaults() throws {
        var session = try json(for: Session(uuid: "s1", feeder: .podcast(uuid: "p1")))
        for key in ["storePlaylistUuid", "autoAdd", "autoFill", "insertMode", "lastInsertedUuid", "lastUsed", "pinnedEpisodeUuids"] {
            session.removeValue(forKey: key)
        }
        try write(["sessions": [session]])

        let store = SessionStore(fileURL: fileURL)

        XCTAssertEqual(store.sessions.count, 1, "a session missing defaulted keys must not wipe the store")
        let loaded = try XCTUnwrap(store.session(uuid: "s1"))
        XCTAssertNil(loaded.storePlaylistUuid)
        XCTAssertEqual(loaded.autoAdd, false)
        XCTAssertEqual(loaded.autoFill, true, "a document written before autoFill existed must decode as Automatic")
        XCTAssertEqual(loaded.insertMode, PlaylistInsertMode.afterLastInserted.rawValue)
        XCTAssertEqual(loaded.lastInsertedUuid, "")
        XCTAssertEqual(loaded.pinnedEpisodeUuids, [], "a document written before pins existed must decode as unpinned")
        XCTAssertEqual(loaded.feeder, .podcast(uuid: "p1"))
    }

    /// A document written by a *newer* build carries keys this one has never heard of.
    func testUnknownSessionKeyIsIgnored() throws {
        var session = try json(for: Session(uuid: "s1", feeder: .allPodcasts))
        session["aFieldFromSomeFutureBuild"] = 42
        try write(["sessions": [session]])

        XCTAssertEqual(SessionStore(fileURL: fileURL).sessions.map(\.uuid), ["s1"])
    }

    /// Blast radius: one unreadable row costs one row. Nothing else.
    func testCorruptSessionDropsOnlyThatSession() throws {
        let first = try json(for: Session(uuid: "good-1", feeder: .podcast(uuid: "p1")))
        let last = try json(for: Session(uuid: "good-2", feeder: .allPodcasts))
        let corrupt: [String: Any] = ["uuid": "bad"] // no feeder — genuinely undecodable

        try write(["sessions": [first, corrupt, last]])

        let store = SessionStore(fileURL: fileURL)

        XCTAssertEqual(store.sessions.map(\.uuid), ["good-1", "good-2"])
    }

    // MARK: - File level

    func testGarbageFileLeavesStoreEmpty() throws {
        try Data("this is not json".utf8).write(to: fileURL)

        XCTAssertTrue(SessionStore(fileURL: fileURL).sessions.isEmpty)
    }

    func testMissingFileLeavesStoreEmpty() {
        XCTAssertTrue(SessionStore(fileURL: fileURL).sessions.isEmpty)
    }

    /// The round trip itself: everything we write, we read back.
    func testRoundTripPreservesEverySessionField() throws {
        let session = Session(
            uuid: "s1",
            storePlaylistUuid: "store-1",
            feeder: .smartPlaylist(uuid: "sp1"),
            autoAdd: true,
            autoFill: false,
            insertMode: PlaylistInsertMode.top.rawValue,
            lastInsertedUuid: "e9",
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            pinnedEpisodeUuids: ["e3", "e7"]
        )
        try write(["sessions": [json(for: session)]])

        let loaded = try XCTUnwrap(SessionStore(fileURL: fileURL).session(uuid: "s1"))

        XCTAssertEqual(loaded, session)
    }
}
