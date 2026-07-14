import UIKit

/// Fork: the one filter control, shared by every episode list.
///
/// **It is a labelled button, not a funnel icon.** That is the whole safety mechanism. The active
/// preset is global and sticky, and a sticky filter you cannot see is how people lose their lists
/// and never work out why — Apple's own support forums are full of it. A highlighted icon is not
/// enough; the control has to *say* what it is filtering by. Apple Podcasts and Feedbin arrived at
/// the same answer independently.
///
/// It goes on every episode list: podcast pages, playlists, smart playlists, and the Session tab.
/// The one exception is the global Inbox, which is already a filtered view (everything unseen) —
/// a preset on top of it would be redundant, and "All Episodes" is a nonsense label on a list that
/// is by definition not all episodes.
enum FilterPresetPicker {

    /// A button that always wears the name of the preset in force.
    ///
    /// `searchActive` is evaluated each time the sheet opens — it decides whether the Reset row is
    /// worth showing (see `present`), so it must reflect the search state *now*, not at build time.
    static func makeButton(
        target: UIViewController,
        searchActive: @escaping () -> Bool = { false },
        onChange: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak target] _ in
            guard let target else { return }
            present(from: target, searchActive: searchActive(), onChange: onChange)
        }, for: .touchUpInside)
        style(button)
        return button
    }

    /// Re-applies the label and the cue. Call whenever the preset (or the theme) may have changed.
    static func style(_ button: UIButton) {
        let preset = FilterPresets.active
        button.setTitle(preset.name, for: .normal)
        button.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        button.semanticContentAttribute = .forceRightToLeft // chevron trails the label
        button.configuration = nil

        // The cue is a bonus, not the mechanism — the label already says what is happening.
        let narrowing = FilterPresets.isNarrowing
        button.tintColor = AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryIcon02)
        button.setTitleColor(AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryText02), for: .normal)
        button.accessibilityLabel = L10n.filterPresetAccessibility(preset.name)
    }

    static func present(from controller: UIViewController, searchActive: Bool = false, onChange: @escaping () -> Void) {
        let picker = OptionsPicker(title: L10n.filters.localizedUppercase)
        let active = FilterPresets.active

        for preset in FilterPresetStore.shared.presets {
            picker.addAction(action: OptionAction(label: preset.name, icon: nil, selected: preset.uuid == active.uuid) {
                FilterPresetStore.shared.activePresetUuid = preset.uuid
                onChange()
            })
        }

        // Fork: "Reset all filters" only appears when there is actually something to reset — a
        // narrowing preset, or an active search. On a clean list it is noise (selecting "All
        // Episodes" from the list above is the reset for the preset alone); its unique value is
        // clearing the search term at the same time, so it also shows when only search is active.
        if FilterPresets.isNarrowing || searchActive {
            picker.addSectionTitle("")
            picker.addAction(action: OptionAction(label: L10n.filterPresetReset, icon: "close") {
                FilterPresetStore.shared.activePresetUuid = nil
                NotificationCenter.postOnMainThread(notification: FilterPresets.resetAll)
                onChange()
            })
        }

        picker.present(from: controller)
    }
}

extension FilterPresets {
    /// "Reset all filters": the preset goes back to All Episodes, and every surface listening to
    /// this clears its search term too.
    static let resetAll = NSNotification.Name(rawValue: "SJFilterPresetsResetAll")
}
