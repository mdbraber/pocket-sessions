import PocketCastsUtils
import SwiftUI

/// Fork: navigation out of the SwiftUI list into the UIKit editor. A tiny reference type so the
/// list view can be built before the hosting controller exists (the controller fills in `host`).
final class FilterPresetsCoordinator {
    weak var host: UIViewController?

    func edit(_ preset: FilterPreset) {
        let editor = FilterPresetEditorViewController(preset: preset, mode: .edit)
        host?.navigationController?.pushViewController(editor, animated: true)
    }
}

/// Fork: the management list for Filter Presets — the one place they are created, edited and
/// deleted.
///
/// Reachable two ways: "Edit Presets…" from inside the picker (in-context, while filtering), and
/// Settings → Filter Presets (the top-level home, matching the feature's global/synced scope). Both
/// land here.
///
/// Built-ins appear with no special-casing: they are seeds, not fixtures, so they edit and delete
/// exactly like the user's own.
struct FilterPresetsListView: View {
    @EnvironmentObject var theme: Theme
    @State private var presets: [FilterPreset] = FilterPresetStore.shared.presets

    let coordinator: FilterPresetsCoordinator

    var body: some View {
        List {
            ForEach(presets) { preset in
                Button {
                    coordinator.edit(preset)
                } label: {
                    HStack {
                        Text(preset.name)
                            .foregroundStyle(theme.primaryText01)
                        Spacer()
                        Image("cs-chevron")
                            .renderingMode(.template)
                            .foregroundStyle(theme.primaryIcon02)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                offsets.map { presets[$0].uuid }.forEach { FilterPresetStore.shared.delete(uuid: $0) }
                reload()
            }
        }
        .navigationTitle(L10n.settingsFilterPresets)
        .onReceive(NotificationCenter.default.publisher(for: FilterPresetStore.changed)) { _ in
            reload()
        }
    }

    private func reload() {
        presets = FilterPresetStore.shared.presets
    }
}

final class FilterPresetsListViewController: PCHostingController<AnyView> {
    private let coordinator = FilterPresetsCoordinator()

    init() {
        let coordinator = coordinator
        super.init(rootView: AnyView(FilterPresetsListView(coordinator: coordinator).setupDefaultEnvironment()))
        coordinator.host = self
    }

    @MainActor dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.settingsFilterPresets
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newTapped))
    }

    @objc private func newTapped() {
        let editor = FilterPresetEditorViewController(preset: FilterPreset(name: L10n.filterPresetNew), mode: .create)
        present(SJUIUtils.navController(for: editor), animated: true)
    }
}
