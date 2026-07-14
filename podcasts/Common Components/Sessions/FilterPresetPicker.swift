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
        scope: FilterScope = .episodes,
        searchActive: @escaping () -> Bool = { false },
        onSelect: @escaping (FilterPreset) -> Void = { _ in },
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
            present(from: target, scope: scope, searchActive: searchActive(), onSelect: onSelect, onChange: onChange)
        }, for: .touchUpInside)
        style(button, scope: scope)
        return button
    }

    /// Re-applies the label and the cue. Call whenever the preset (or the theme) may have changed.
    static func style(_ button: UIButton, scope: FilterScope = .episodes) {
        let preset = FilterPresets.active(scope)
        button.setTitle(preset.name, for: .normal)
        button.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        button.semanticContentAttribute = .forceRightToLeft // chevron trails the label
        button.configuration = nil
        // The filter label sits hard against the right edge of its slot — the control is the
        // rightmost thing on the info line, so it right-aligns.
        button.contentHorizontalAlignment = .right

        // The cue is a bonus, not the mechanism — the label already says what is happening.
        let narrowing = FilterPresets.isNarrowing(scope)
        button.tintColor = AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryIcon02)
        button.setTitleColor(AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryText02), for: .normal)
        button.accessibilityLabel = L10n.filterPresetAccessibility(preset.name)
    }

    static func present(from controller: UIViewController, scope: FilterScope = .episodes, searchActive: Bool = false, onSelect: @escaping (FilterPreset) -> Void = { _ in }, onChange: @escaping () -> Void) {
        let picker = OptionsPicker(title: L10n.filters.localizedUppercase)
        let active = FilterPresets.active(scope)

        for preset in FilterPresetStore.shared.enabledPresets {
            picker.addAction(action: OptionAction(label: preset.name, icon: nil, selected: preset.uuid == active.uuid) {
                FilterPresetStore.shared.setActivePresetUuid(preset.uuid, for: scope)
                onSelect(preset) // apply the preset's sort/group to the list (then overridable)
                onChange()
            })
        }

        picker.addSectionTitle("")

        // Managing presets is one hop deeper than picking one: a picker row is a single tap target
        // that already means "apply this preset", so editing cannot ride on the same rows.
        picker.addAction(action: OptionAction(label: L10n.filterPresetEdit, icon: "podcast-settings") { [weak controller] in
            guard let controller else { return }
            // The picker sheet auto-dismisses on this tap; presenting the list on the same runloop
            // would race that dismissal, so defer one loop. (SessionLinking hits the same thing.)
            DispatchQueue.main.async {
                let list = FilterPresetsListViewController()
                controller.present(SJUIUtils.navController(for: list), animated: true)
            }
        })

        // No "Reset all filters" here — selecting "All Episodes" from the list resets the preset,
        // and Reset lives in the management list's ⋯ menu. (Kept off the everyday picker.)
        picker.present(from: controller)
    }
}

extension FilterPresets {
    /// "Reset all filters": the preset goes back to All Episodes, and every surface listening to
    /// this clears its search term too.
    static let resetAll = NSNotification.Name(rawValue: "SJFilterPresetsResetAll")
}
