import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Decode-safety and seeding for `FilterPresetStore`, to the same contract as the other two stores.
final class FilterPresetStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filter-presets-\(UUID().uuidString).json")
        UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-episodes")
        UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-session")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-episodes")
        UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-session")
        fileURL = nil
        super.tearDown()
    }

    private func write(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document).write(to: fileURL)
    }

    private func json(for preset: FilterPreset) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
    }

    // MARK: - Seeding

    func testBuiltInsSeedOnFirstLoad() {
        let store = FilterPresetStore(fileURL: fileURL)

        XCTAssertEqual(store.presets.map(\.uuid), FilterPreset.builtIns.map(\.uuid))
    }

    /// Built-ins are seeds, not fixtures. Delete one and it must STAY deleted — otherwise the
    /// "editable and deletable" promise is a lie the next time the app launches.
    func testADeletedBuiltInStaysDeleted() {
        let store = FilterPresetStore(fileURL: fileURL)
        store.delete(uuid: "preset-starred")

        let reopened = FilterPresetStore(fileURL: fileURL)

        XCTAssertFalse(reopened.presets.contains { $0.uuid == "preset-starred" })
    }

    func testAnEditedBuiltInKeepsItsEdit() {
        let store = FilterPresetStore(fileURL: fileURL)
        var unseen = try! XCTUnwrap(store.preset(uuid: "preset-unseen"))
        unseen.name = "Not Yet Looked At"
        store.upsert(unseen)

        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).preset(uuid: "preset-unseen")?.name, "Not Yet Looked At")
    }

    // MARK: - The active preset

    func testTheActivePresetIsAllEpisodesByDefault() {
        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).activePreset(for: .episodes).uuid, FilterPreset.allEpisodes.uuid)
    }

    /// Deleting the preset you are currently looking through must not leave the app filtering by a
    /// ghost.
    func testDeletingTheActivePresetFallsBackToAllEpisodes() {
        let store = FilterPresetStore(fileURL: fileURL)
        store.setActivePresetUuid("preset-starred", for: .episodes)

        store.delete(uuid: "preset-starred")

        XCTAssertNil(store.activePresetUuid(for: .episodes))
        XCTAssertEqual(store.activePreset(for: .episodes).uuid, FilterPreset.allEpisodes.uuid)
    }

    // MARK: - Decode safety

    func testAPresetMissingDefaultedKeysDecodesRatherThanWipingTheStore() throws {
        var preset = try json(for: FilterPreset(name: "Long Reads", starred: true))
        for key in ["iconId", "playingStatus", "downloadStatus", "filterDuration", "longerThan", "shorterThan", "filterHours", "sortType"] {
            preset.removeValue(forKey: key)
        }
        try write(["presets": [preset], "seeded": true])

        let store = FilterPresetStore(fileURL: fileURL)

        XCTAssertEqual(store.presets.count, 1, "a preset missing defaulted keys must not wipe the store")
        let loaded = try XCTUnwrap(store.presets.first)
        XCTAssertEqual(loaded.starred, true)
        XCTAssertTrue(loaded.playingStatus.isEmpty)
        XCTAssertEqual(loaded.sortType, PlaylistSort.newestToOldest.rawValue)
    }

    /// A nil rule means "don't care". It is written as an absent key, so it MUST read back as nil
    /// rather than as some creation-time default — otherwise a preset silently narrows on reload.
    func testANilRuleRoundTripsAsNil() throws {
        let store = FilterPresetStore(fileURL: fileURL)
        store.upsert(FilterPreset(uuid: "p", name: "Anything", archived: nil))

        let loaded = try XCTUnwrap(FilterPresetStore(fileURL: fileURL).preset(uuid: "p"))

        XCTAssertNil(loaded.archived, "a 'don't care' rule must not come back as a constraint")
    }

    func testCorruptPresetDropsOnlyThatPreset() throws {
        let good = try json(for: FilterPreset(uuid: "good", name: "Good"))
        let corrupt: [String: Any] = ["name": "no uuid"]

        try write(["presets": [good, corrupt], "seeded": true])

        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).presets.map(\.uuid), ["good"])
    }

    func testGarbageFileSeedsFreshRatherThanCrashing() throws {
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).presets.map(\.uuid), FilterPreset.builtIns.map(\.uuid))
    }
}
