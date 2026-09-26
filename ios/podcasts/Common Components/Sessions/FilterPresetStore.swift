import Foundation
import PocketCastsUtils

/// A value snapshot of the preset document, for cloud-sync diffing.
struct FilterPresetStoreSnapshot {
    let presets: [FilterPreset]

    fileprivate init(document: FilterPresetStore.Document) {
        presets = document.presets
    }
}

/// Fork: the user's Filter Presets.
///
/// Its own file, like `InboxStore`. Presets are a filter feature, not session state — and the one
/// time everything shared a document, a single bad key took the whole thing with it. Separate files
/// contain that.
///
/// The **active** preset is deliberately NOT in here: it is a device-local UI selection
/// (`UserDefaults`), not synced content. Which preset you happen to be looking through on this
/// phone is nobody else's business.
final class FilterPresetStore {
    static let shared = FilterPresetStore()

    static let changed = NSNotification.Name(rawValue: "SJFilterPresetsChanged")

    private static let activePresetKey = "SJActiveFilterPreset"

    struct Document: Codable {
        var presets: [FilterPreset] = []
        /// Seeded once. Without this, deleting a built-in would just resurrect it on next launch —
        /// and built-ins are seeds, not fixtures.
        var seeded: Bool = false
        /// Which built-ins have been seeded, so one added in a later build still arrives for
        /// existing users — once — without resurrecting any they deleted.
        var seededBuiltInUuids: [String] = []

        init() {}

        enum CodingKeys: String, CodingKey {
            case presets, seeded, seededBuiltInUuids
        }

        /// The built-ins that shipped before `seededBuiltInUuids` existed. A document seeded by an
        /// older build has had exactly these.
        static let originalBuiltInUuids = ["preset-all", "preset-unseen", "preset-downloaded", "preset-in-progress", "preset-starred"]

        // CRITICAL: decodeIfPresent for every key, and element-wise leniency for the array, so one
        // unreadable preset costs one preset rather than the document. See SessionStoreDecodeTests.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            presets = (try c.decodeIfPresent([LenientlyDecoded<FilterPreset>].self, forKey: .presets) ?? [])
                .compactMap(\.value)
            seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
            seededBuiltInUuids = try c.decodeIfPresent([String].self, forKey: .seededBuiltInUuids)
                ?? (seeded ? Self.originalBuiltInUuids : [])
        }
    }

    private var document = Document()
    private let queue = DispatchQueue(label: "au.com.pocketcasts.filterpresetstore")
    private let fileURL: URL

    static var defaultFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("filter-presets.json")
    }

    /// `fileURL` is injectable so the decode-safety tests can point a store at a temp file.
    init(fileURL: URL = FilterPresetStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
        seedIfNeeded()
    }

    // MARK: - Presets

    var presets: [FilterPreset] {
        queue.sync { document.presets }
    }

    func preset(uuid: String) -> FilterPreset? {
        queue.sync { document.presets.first { $0.uuid == uuid } }
    }

    func upsert(_ preset: FilterPreset) {
        mutate { document in
            if let index = document.presets.firstIndex(where: { $0.uuid == preset.uuid }) {
                document.presets[index] = preset
            } else {
                document.presets.append(preset)
            }
        }
    }

    /// Presets that show in the quick picker — enabled only, in stored order.
    var enabledPresets: [FilterPreset] {
        queue.sync { document.presets.filter(\.enabled) }
    }

    /// Reorders the stored presets (drag in the management list).
    func move(fromOffsets: IndexSet, toOffset: Int) {
        mutate { $0.presets.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func delete(uuid: String) {
        mutate { $0.presets.removeAll { $0.uuid == uuid } }
        // Clear it from whichever scope was pointing at it.
        for scope in FilterScope.allCases where activePresetUuid(for: scope) == uuid {
            setActivePresetUuid(nil, for: scope)
        }
    }

    /// Built-ins are seeds, not fixtures: each seeds once, and after that it is the user's — as
    /// editable and deletable as any preset they made themselves. A built-in added in a later build
    /// seeds on its first launch, right after the built-in it follows.
    private func seedIfNeeded() {
        let seeded = queue.sync { Set(document.seededBuiltInUuids) }
        let builtIns = FilterPreset.builtIns
        guard builtIns.contains(where: { !seeded.contains($0.uuid) }) else { return }
        mutate { document in
            for (index, builtIn) in builtIns.enumerated() where !seeded.contains(builtIn.uuid) {
                if document.presets.contains(where: { $0.uuid == builtIn.uuid }) { continue }
                let predecessor = builtIns[..<index].last { previous in document.presets.contains { $0.uuid == previous.uuid } }
                let position = predecessor.flatMap { previous in document.presets.firstIndex { $0.uuid == previous.uuid } }
                    .map { $0 + 1 } ?? min(index, document.presets.count)
                document.presets.insert(builtIn, at: position)
            }
            document.seeded = true
            document.seededBuiltInUuids = builtIns.map(\.uuid)
        }
    }

    // MARK: - The active preset (device-local)

    /// Global and sticky **per scope**: one selection each for the Episodes list and the Session
    /// lineup, shared across every page, persisted across launches. They are independent — filtering
    /// the Episodes list does not reshape the hand-made Session lineup.
    ///
    /// Sticky is safe here for one reason only — the control is **labelled with the active preset**,
    /// so an invisible filter is structurally impossible. (Sticky filters are dangerous exactly when
    /// you cannot see them.) Nil means "All Episodes".
    func activePresetUuid(for scope: FilterScope) -> String? {
        UserDefaults.standard.string(forKey: "\(Self.activePresetKey)-\(scope.rawValue)")
    }

    func setActivePresetUuid(_ uuid: String?, for scope: FilterScope) {
        UserDefaults.standard.set(uuid, forKey: "\(Self.activePresetKey)-\(scope.rawValue)")
        NotificationCenter.postChangedWithoutBlocking(Self.changed)
    }

    /// The preset in force for a scope right now: the chosen one, else the scope's default, else All
    /// Episodes (the default may have been deleted). A preset the list can't use is never in force
    /// there — it is offered nowhere on that list, so it can't be the label: a contextual preset
    /// needs a session behind the list, and a podcast/folder-limited one needs a list that mixes
    /// podcasts (`singlePodcast` lists show one podcast, so the limit could only no-op or empty it).
    func activePreset(for scope: FilterScope, singlePodcast: Bool = false) -> FilterPreset {
        let usable = { (preset: FilterPreset) in Self.isUsable(preset, in: scope, singlePodcast: singlePodcast) }
        if let uuid = activePresetUuid(for: scope), let preset = preset(uuid: uuid), usable(preset) {
            return preset
        }
        if let preset = preset(uuid: scope.defaultPresetUuid), usable(preset) {
            return preset
        }
        return preset(uuid: FilterPreset.allEpisodes.uuid) ?? FilterPreset.allEpisodes
    }

    /// The presets the quick picker offers for a list — only the ones it can use (see `activePreset`).
    func pickerPresets(for scope: FilterScope, singlePodcast: Bool = false) -> [FilterPreset] {
        enabledPresets.filter { Self.isUsable($0, in: scope, singlePodcast: singlePodcast) }
    }

    static func isUsable(_ preset: FilterPreset, in scope: FilterScope, singlePodcast: Bool) -> Bool {
        (scope.hasSessionContext || !preset.isContextual) && (!singlePodcast || !preset.isScoped)
    }

    // MARK: - Cloud

    var cloudDiffHandler: ((_ old: FilterPresetStoreSnapshot, _ new: FilterPresetStoreSnapshot) -> Void)?
    private var applyingRemote = false

    var snapshot: FilterPresetStoreSnapshot {
        queue.sync { FilterPresetStoreSnapshot(document: document) }
    }

    func applyRemote(_ block: @escaping () -> Void) {
        applyingRemote = true
        block()
        applyingRemote = false
    }

    // MARK: - Persistence

    private func mutate(_ block: (inout Document) -> Void) {
        queue.sync {
            let old = document
            block(&document)
            save()
            if !applyingRemote, let handler = cloudDiffHandler {
                handler(FilterPresetStoreSnapshot(document: old), FilterPresetStoreSnapshot(document: document))
            }
        }
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
