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
        for scope in FilterScope.allCases {
            UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-\(scope.rawValue)")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        for scope in FilterScope.allCases {
            UserDefaults.standard.removeObject(forKey: "SJActiveFilterPreset-\(scope.rawValue)")
        }
        fileURL = nil
        super.tearDown()
    }

    /// A document every current built-in has already been seeded into — for tests about decoding,
    /// not seeding.
    private var fullySeeded: [String: Any] {
        ["seeded": true, "seededBuiltInUuids": FilterPreset.builtIns.map(\.uuid)]
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

    /// A built-in added in a later build reaches a store seeded by an older one — once, right after
    /// the built-in it follows.
    func testABuiltInAddedLaterSeedsIntoAnOlderStore() throws {
        let older = try FilterPreset.builtIns.prefix(5).map { try json(for: $0) }
        let mine = try json(for: FilterPreset(uuid: "mine", name: "Mine"))
        try write(["presets": older + [mine], "seeded": true])

        let store = FilterPresetStore(fileURL: fileURL)

        XCTAssertEqual(store.presets.map(\.uuid), ["preset-all", "preset-unseen", "preset-downloaded", "preset-in-progress", "preset-starred", "preset-not-in-session", "mine"])
    }

    func testABuiltInAddedLaterStaysDeletedOnceSeeded() throws {
        let older = try FilterPreset.builtIns.prefix(5).map { try json(for: $0) }
        try write(["presets": older, "seeded": true])
        FilterPresetStore(fileURL: fileURL).delete(uuid: "preset-not-in-session")

        XCTAssertFalse(FilterPresetStore(fileURL: fileURL).presets.contains { $0.uuid == "preset-not-in-session" })
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

    /// A session's Episodes list opens on what could still be added to it.
    func testTheSessionEpisodesScopeDefaultsToNotInSession() {
        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).activePreset(for: .sessionEpisodes).uuid, FilterPreset.notInThisSession.uuid)
    }

    /// A contextual preset means nothing without a session behind the list, so the scopes without
    /// one never offer it — and never wear its label, even if one was stored.
    func testContextualPresetsStayOffScopesWithoutASession() {
        let store = FilterPresetStore(fileURL: fileURL)
        store.setActivePresetUuid(FilterPreset.notInThisSession.uuid, for: .episodes)

        XCTAssertEqual(store.activePreset(for: .episodes).uuid, FilterPreset.allEpisodes.uuid)
        XCTAssertFalse(store.pickerPresets(for: .episodes).contains { $0.isContextual })
        XCTAssertTrue(store.pickerPresets(for: .sessionEpisodes).contains { $0.uuid == FilterPreset.notInThisSession.uuid })
    }

    /// A podcast/folder-limited preset can only no-op on a list of one podcast, so it isn't offered
    /// there and never labels it — but still works where lists mix podcasts.
    func testPodcastLimitedPresetsStayOffSinglePodcastLists() {
        let store = FilterPresetStore(fileURL: fileURL)
        store.upsert(FilterPreset(uuid: "scoped", name: "News", podcastUuids: ["pod-a"]))
        store.setActivePresetUuid("scoped", for: .episodes)

        XCTAssertEqual(store.activePreset(for: .episodes, singlePodcast: true).uuid, FilterPreset.allEpisodes.uuid)
        XCTAssertFalse(store.pickerPresets(for: .episodes, singlePodcast: true).contains { $0.uuid == "scoped" })
        XCTAssertEqual(store.activePreset(for: .episodes).uuid, "scoped")
        XCTAssertTrue(store.pickerPresets(for: .episodes).contains { $0.uuid == "scoped" })
    }

    /// With its default deleted, the session-Episodes scope falls back to All Episodes.
    func testTheSessionEpisodesScopeFallsBackWhenItsDefaultIsDeleted() {
        let store = FilterPresetStore(fileURL: fileURL)
        store.delete(uuid: FilterPreset.notInThisSession.uuid)

        XCTAssertEqual(store.activePreset(for: .sessionEpisodes).uuid, FilterPreset.allEpisodes.uuid)
    }

    // MARK: - Decode safety

    func testAPresetMissingDefaultedKeysDecodesRatherThanWipingTheStore() throws {
        var preset = try json(for: FilterPreset(name: "Long Reads", starred: true))
        for key in ["iconId", "playingStatus", "downloadStatus", "filterDuration", "longerThan", "shorterThan", "filterHours", "sortOrder", "groupBy"] {
            preset.removeValue(forKey: key)
        }
        try write(fullySeeded.merging(["presets": [preset]]) { $1 })

        let store = FilterPresetStore(fileURL: fileURL)

        XCTAssertEqual(store.presets.count, 1, "a preset missing defaulted keys must not wipe the store")
        let loaded = try XCTUnwrap(store.presets.first)
        XCTAssertEqual(loaded.starred, true)
        XCTAssertTrue(loaded.playingStatus.isEmpty)
        XCTAssertNil(loaded.sortOrder)
    }

    /// A nil rule means "don't care". It is written as an absent key, so it MUST read back as nil
    /// rather than as some creation-time default — otherwise a preset silently narrows on reload.
    func testANilRuleRoundTripsAsNil() throws {
        let store = FilterPresetStore(fileURL: fileURL)
        store.upsert(FilterPreset(uuid: "p", name: "Anything", archived: nil))

        let loaded = try XCTUnwrap(FilterPresetStore(fileURL: fileURL).preset(uuid: "p"))

        XCTAssertNil(loaded.archived, "a 'don't care' rule must not come back as a constraint")
    }

    /// The old `groupBy` key stored 0 for both "never set" and "None"; it reads as unchanged. A
    /// grouping it named survives, and the new key keeps an explicit None.
    func testGroupingSeedsReadFromOldAndNewKeys() throws {
        var legacyUnset = try json(for: FilterPreset(uuid: "legacy-unset", name: "A"))
        legacyUnset.removeValue(forKey: "groupSeed")
        legacyUnset["groupBy"] = 0
        var legacyPodcast = try json(for: FilterPreset(uuid: "legacy-podcast", name: "B"))
        legacyPodcast.removeValue(forKey: "groupSeed")
        legacyPodcast["groupBy"] = EpisodeGroupBy.podcast.rawValue
        let explicitNone = try json(for: FilterPreset(uuid: "none", name: "C", sortOrder: FilterPreset.manualSortOrder, groupBy: EpisodeGroupBy.none.rawValue))
        try write(fullySeeded.merging(["presets": [legacyUnset, legacyPodcast, explicitNone]]) { $1 })

        let store = FilterPresetStore(fileURL: fileURL)

        XCTAssertNil(store.preset(uuid: "legacy-unset")?.groupSeed)
        XCTAssertEqual(store.preset(uuid: "legacy-podcast")?.groupSeed, .podcast)
        XCTAssertEqual(store.preset(uuid: "none")?.groupSeed, EpisodeGroupBy.none)
        XCTAssertEqual(store.preset(uuid: "none")?.sortSeed, .manual)
    }

    func testCorruptPresetDropsOnlyThatPreset() throws {
        let good = try json(for: FilterPreset(uuid: "good", name: "Good"))
        let corrupt: [String: Any] = ["name": "no uuid"]

        try write(fullySeeded.merging(["presets": [good, corrupt]]) { $1 })

        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).presets.map(\.uuid), ["good"])
    }

    func testGarbageFileSeedsFreshRatherThanCrashing() throws {
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(FilterPresetStore(fileURL: fileURL).presets.map(\.uuid), FilterPreset.builtIns.map(\.uuid))
    }
}
