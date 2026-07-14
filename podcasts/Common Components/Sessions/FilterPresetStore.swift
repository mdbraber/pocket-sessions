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

        init() {}

        enum CodingKeys: String, CodingKey {
            case presets, seeded
        }

        // CRITICAL: decodeIfPresent for every key, and element-wise leniency for the array, so one
        // unreadable preset costs one preset rather than the document. See SessionStoreDecodeTests.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            presets = (try c.decodeIfPresent([LenientlyDecoded<FilterPreset>].self, forKey: .presets) ?? [])
                .compactMap(\.value)
            seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
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

    func delete(uuid: String) {
        mutate { $0.presets.removeAll { $0.uuid == uuid } }
        if activePresetUuid == uuid {
            activePresetUuid = nil
        }
    }

    /// Built-ins are seeds, not fixtures: they seed once, and after that they are the user's — as
    /// editable and deletable as any preset they made themselves.
    private func seedIfNeeded() {
        guard !queue.sync(execute: { document.seeded }) else { return }
        mutate { document in
            document.presets = FilterPreset.builtIns + document.presets
            document.seeded = true
        }
    }

    // MARK: - The active preset (device-local)

    /// Global and sticky: one selection, shared across every page, persisted across launches.
    ///
    /// Sticky is safe here for one reason only — the control is **labelled with the active preset**,
    /// so an invisible filter is structurally impossible. (Sticky filters are dangerous exactly when
    /// you cannot see them.) Nil means "All Episodes".
    var activePresetUuid: String? {
        get { UserDefaults.standard.string(forKey: Self.activePresetKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.activePresetKey)
            NotificationCenter.postOnMainThread(notification: Self.changed)
        }
    }

    /// The preset in force right now. Falls back to All Episodes if the active one was deleted.
    var activePreset: FilterPreset {
        guard let uuid = activePresetUuid, let preset = preset(uuid: uuid) else {
            return preset(uuid: FilterPreset.allEpisodes.uuid) ?? FilterPreset.allEpisodes
        }
        return preset
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
