import Combine
import PocketCastsUtils
import SwiftUI

/// Fork: navigation out of the SwiftUI list into the UIKit editor, plus the shared edit-mode state.
/// A reference type so the list view can be built before the hosting controller exists.
final class FilterPresetsListModel: ObservableObject {
    @Published var editMode: EditMode = .inactive
    weak var host: UIViewController?

    func edit(_ preset: FilterPreset) {
        let editor = FilterPresetEditorViewController(preset: preset, mode: .edit)
        host?.navigationController?.pushViewController(editor, animated: true)
    }
}

/// Fork: the management list for Filter Presets — the one place they are created, edited, reordered,
/// enabled/disabled and deleted.
///
/// Reachable two ways: "Edit Presets…" from inside the picker, and Settings → Filter Presets.
///
/// A preset can be **disabled** — it stays here but drops out of the quick picker, keeping that list
/// compact. Built-ins are seeds, not fixtures: they enable/disable, reorder and delete like any
/// other.
struct FilterPresetsListView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: FilterPresetsListModel
    @State private var presets: [FilterPreset] = FilterPresetStore.shared.presets

    // Deletion is permanent (built-ins are never reseeded), so a swipe-delete confirms first.
    @State private var pendingDelete: FilterPreset?

    var body: some View {
        List {
            ForEach(presets) { preset in
                // The whole row opens the preset — a chevron says so. Whether it shows in the
                // Filters menu is set inside; a preset that's off stays here, dimmed.
                Button {
                    model.edit(preset)
                } label: {
                    HStack(spacing: 12) {
                        Text(preset.name)
                            .foregroundStyle(preset.enabled ? theme.primaryText01 : theme.primaryText02)
                        Spacer()
                        if !preset.enabled {
                            Text(L10n.off).foregroundStyle(theme.primaryText02)
                        }
                        Image("cs-chevron").renderingMode(.template).foregroundStyle(theme.primaryIcon02)
                    }
                    .contentShape(Rectangle())
                    .opacity(preset.enabled ? 1 : 0.6)
                }
                .buttonStyle(.plain)
            }
            .onMove { from, to in
                FilterPresetStore.shared.move(fromOffsets: from, toOffset: to)
                reload()
            }
            .onDelete { offsets in
                pendingDelete = offsets.first.map { presets[$0] }
            }
        }
        .environment(\.editMode, $model.editMode)
        .navigationTitle(L10n.settingsFilterPresets)
        .alert(L10n.filterPresetDeleteConfirm(pendingDelete?.name ?? ""), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.delete, role: .destructive) {
                if let preset = pendingDelete {
                    FilterPresetStore.shared.delete(uuid: preset.uuid)
                    reload()
                }
                pendingDelete = nil
            }
            Button(L10n.cancel, role: .cancel) { pendingDelete = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: FilterPresetStore.changed)) { _ in
            reload()
        }
    }

    private func reload() {
        presets = FilterPresetStore.shared.presets
    }
}

final class FilterPresetsListViewController: PCHostingController<AnyView> {
    private let model: FilterPresetsListModel
    private var cancellable: AnyCancellable?

    init() {
        let model = FilterPresetsListModel()
        self.model = model
        super.init(rootView: AnyView(FilterPresetsListView(model: model).setupDefaultEnvironment()))
        model.host = self
        // Bars swap between ⋯ (normal) and Done (reordering) as edit mode changes.
        cancellable = model.$editMode.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateBars() }
    }

    @MainActor dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.settingsFilterPresets
        updateBars()
    }

    private func updateBars() {
        // New preset leads the bar; management (⋯) trails it.
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newTapped))

        if model.editMode == .active {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneReordering))
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain, target: self, action: #selector(optionsTapped))
        }
    }

    @objc private func newTapped() {
        let editor = FilterPresetEditorViewController(preset: FilterPreset(name: L10n.filterPresetNew), mode: .create)
        present(SJUIUtils.navController(for: editor), animated: true)
    }

    @objc private func doneReordering() {
        model.editMode = .inactive
    }

    @objc private func optionsTapped() {
        let picker = OptionsPicker(title: nil)
        picker.addAction(action: OptionAction(label: L10n.filterPresetReorder, icon: "option-multiselect") { [weak self] in
            self?.model.editMode = .active
        })
        // "Reset all filters" — the same clear the picker offers, reachable from management too.
        picker.addAction(action: OptionAction(label: L10n.filterPresetReset, icon: "close") {
            // Each scope back to its own default (a session's Episodes list: "Not in Session").
            for scope in FilterScope.allCases {
                FilterPresetStore.shared.setActivePresetUuid(nil, for: scope)
            }
            NotificationCenter.postOnMainThread(notification: FilterPresets.resetAll)
        })
        picker.present(from: self)
    }
}
