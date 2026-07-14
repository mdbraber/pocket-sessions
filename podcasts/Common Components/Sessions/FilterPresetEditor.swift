import PocketCastsDataModel
import SwiftUI

/// Fork: the Filter Preset editor.
///
/// This is a purpose-built form over `FilterPreset`, NOT a copy of the smart-playlist rule editor.
/// The plan called for a copy, but the copy is bound to `EpisodeFilter` — a reference type with
/// `*SmartRuleApplied` flags, a podcast picker, and a live-preview refresh operation. `FilterPreset`
/// is a value type with tri-state `Rule`s and `Set`s, so a form over it is both simpler and a truer
/// realisation of "own the editor": there is nothing of Pocket Casts' schema to inherit.
///
/// A binary rule (`Rule` = `Bool?`) is a three-way segmented control; a multi-value axis is a set of
/// toggles where all-on or all-off means "any", exactly as the query builder reads it.
final class FilterPresetEditorModel: ObservableObject {
    enum Mode { case create, edit }

    @Published var preset: FilterPreset {
        didSet {
            // Editing an existing preset saves live, matching the smart-playlist editor. A new
            // preset is only committed on Save, so cancelling leaves no junk behind.
            if mode == .edit { FilterPresetStore.shared.upsert(preset) }
        }
    }

    let mode: Mode

    init(preset: FilterPreset, mode: Mode) {
        self.preset = preset
        self.mode = mode
    }

    func commit() {
        FilterPresetStore.shared.upsert(preset)
    }
}

/// A binary rule as three explicit choices — the nil ("any") state made visible.
private enum TriState: Hashable {
    case any, yes, no

    init(_ rule: Rule) {
        switch rule {
        case .none: self = .any
        case .some(true): self = .yes
        case .some(false): self = .no
        }
    }

    var rule: Rule {
        switch self {
        case .any: nil
        case .yes: true
        case .no: false
        }
    }
}

struct FilterPresetEditorView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: FilterPresetEditorModel
    @State private var showingScope = false

    var body: some View {
        Form {
            Section {
                TextField(L10n.filterPresetNamePlaceholder, text: Binding(
                    get: { model.preset.name },
                    set: { model.preset.name = $0 }
                ))
            }

            // Multi-value axes: a toggle per option. All-on or all-off = "any".
            Section(header: Text(L10n.filterEpisodeStatus)) {
                setToggle(L10n.statusUnplayed, .unplayed, keyPath: \.playingStatus)
                setToggle(L10n.inProgress, .inProgress, keyPath: \.playingStatus)
                setToggle(L10n.statusPlayed, .played, keyPath: \.playingStatus)
            }

            Section(header: Text(L10n.filterDownloadStatus)) {
                setToggle(L10n.statusDownloaded, .downloaded, keyPath: \.downloadStatus)
                setToggle(L10n.statusDownloading, .downloading, keyPath: \.downloadStatus)
                setToggle(L10n.statusNotDownloaded, .notDownloaded, keyPath: \.downloadStatus)
            }

            // Scope: which podcasts/folders. A multi-select sheet; empty = all. (A sheet, not a
            // push — this SwiftUI form is hosted inside a UIKit nav stack, so a NavigationLink has
            // nothing to push onto.)
            Section {
                Button {
                    showingScope = true
                } label: {
                    HStack {
                        Text(L10n.filterPresetRuleScope).foregroundStyle(theme.primaryText01)
                        Spacer()
                        Text(model.preset.scopeSummary).foregroundStyle(theme.primaryText02)
                        Image("cs-chevron").renderingMode(.template).foregroundStyle(theme.primaryIcon02)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Binary axes: three-way segmented controls.
            Section(header: Text(L10n.filters)) {
                triStateRow(L10n.filterPresetRuleUnseen, positive: L10n.episodeUnseen, negative: L10n.episodeSeen, keyPath: \.unseen)
                triStateRow(L10n.filterPresetRuleSession, positive: L10n.filterPresetInSession, negative: L10n.filterPresetNotInSession, keyPath: \.inSession)
                triStateRow(L10n.statusStarred, positive: L10n.statusStarred, negative: L10n.statusNotStarred, keyPath: \.starred)
                triStateRow(L10n.podcastArchived, positive: L10n.podcastArchived, negative: L10n.filterPresetNotArchived, keyPath: \.archived)
            }

            Section(header: Text(L10n.filterMediaType)) {
                Picker(L10n.filterMediaType, selection: Binding(
                    get: { model.preset.mediaType },
                    set: { model.preset.mediaType = $0 }
                )) {
                    Text(L10n.filterValueAll).tag(MediaTypeRule?.none)
                    Text(L10n.filterMediaTypeAudio).tag(MediaTypeRule?.some(.audio))
                    Text(L10n.filterMediaTypeVideo).tag(MediaTypeRule?.some(.video))
                }
            }

            Section(header: Text(L10n.filterReleaseDate)) {
                Picker(L10n.filterReleaseDate, selection: Binding(
                    get: { ReleaseDateFilterOption(rawValue: model.preset.filterHours) ?? .anytime },
                    set: { model.preset.filterHours = $0.rawValue }
                )) {
                    ForEach([ReleaseDateFilterOption.anytime, .last24hours, .last3Days, .lastWeek, .last2Weeks, .lastMonth], id: \.self) {
                        Text($0.description).tag($0)
                    }
                }
            }

            Section {
                Toggle(L10n.filterPresetDurationLimit, isOn: Binding(
                    get: { model.preset.filterDuration },
                    set: { model.preset.filterDuration = $0 }
                ))
                if model.preset.filterDuration {
                    stepperRow(L10n.filterPresetLongerThan, keyPath: \.longerThan)
                    stepperRow(L10n.filterPresetShorterThan, keyPath: \.shorterThan)
                }
            }

            Section(header: Text(L10n.sortBy)) {
                Picker(L10n.sortBy, selection: Binding(
                    get: { model.preset.sortType },
                    set: { model.preset.sortType = $0 }
                )) {
                    Text(L10n.podcastsEpisodeSortNewestToOldest).tag(PlaylistSort.newestToOldest.rawValue)
                    Text(L10n.podcastsEpisodeSortOldestToNewest).tag(PlaylistSort.oldestToNewest.rawValue)
                    Text(L10n.podcastsEpisodeSortShortestToLongest).tag(PlaylistSort.shortestToLongest.rawValue)
                    Text(L10n.podcastsEpisodeSortLongestToShortest).tag(PlaylistSort.longestToShortest.rawValue)
                }
            }
        }
        .navigationTitle(model.mode == .create ? L10n.filterPresetNew : model.preset.name)
        .sheet(isPresented: $showingScope) {
            NavigationStack {
                FilterPresetScopePicker(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.done) { showingScope = false }
                        }
                    }
            }
            .setupDefaultEnvironment()
        }
    }

    // MARK: - Row builders

    private func setToggle<Option: Hashable>(_ label: String, _ option: Option, keyPath: WritableKeyPath<FilterPreset, Set<Option>>) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.preset[keyPath: keyPath].contains(option) },
            set: { on in
                if on { model.preset[keyPath: keyPath].insert(option) }
                else { model.preset[keyPath: keyPath].remove(option) }
            }
        ))
    }

    private func triStateRow(_ label: String, positive: String, negative: String, keyPath: WritableKeyPath<FilterPreset, Rule>) -> some View {
        Picker(label, selection: Binding(
            get: { TriState(model.preset[keyPath: keyPath]) },
            set: { model.preset[keyPath: keyPath] = $0.rule }
        )) {
            Text(L10n.filterValueAll).tag(TriState.any)
            Text(positive).tag(TriState.yes)
            Text(negative).tag(TriState.no)
        }
    }

    private func stepperRow(_ label: String, keyPath: WritableKeyPath<FilterPreset, Int32>) -> some View {
        Stepper(value: Binding(
            get: { model.preset[keyPath: keyPath] },
            set: { model.preset[keyPath: keyPath] = max(0, $0) }
        ), in: 0 ... 600) {
            Text("\(label): \(L10n.filterPresetMinutes(model.preset[keyPath: keyPath].localized()))")
        }
    }
}

/// Hosts the editor. In create mode it carries Save/Cancel; in edit mode it saves live and just
/// pops.
final class FilterPresetEditorViewController: PCHostingController<AnyView> {
    private let model: FilterPresetEditorModel

    init(preset: FilterPreset, mode: FilterPresetEditorModel.Mode) {
        let model = FilterPresetEditorModel(preset: preset, mode: mode)
        self.model = model
        super.init(rootView: AnyView(FilterPresetEditorView(model: model).setupDefaultEnvironment()))
    }

    @MainActor dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard model.mode == .create else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        model.commit()
        dismiss(animated: true)
    }
}
