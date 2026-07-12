import UIKit
import SwiftUI
import PocketCastsDataModel

/// Fork: the Playlist Folder row — the podcast folder look: a folder-colored tile with
/// the members' artwork composited 2×2, name and playlist count beside it. Geometry
/// matches NewPlaylistCell (56pt tile, 81pt row, hairline separator).
class PlaylistFolderCell: ThemeableCell {
    static let reuseIdentifier = "PlaylistFolderCell"

    private let separatorView = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .disclosureIndicator
        self.style = .primaryUi02
        updateColor()

        separatorView.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)
        bringSubviewToFront(separatorView)
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(folder: PlaylistFolder, count: Int) {
        let podcastUuids = PlaylistFolderManager.shared.previewPodcastUuids(inFolder: folder.uuid)
        contentConfiguration = UIHostingConfiguration {
            HStack(spacing: 12) {
                PlaylistFolderPreviewTile(color: folder.color, podcastUuids: podcastUuids)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(Font(UIFont.font(ofSize: 16, weight: .medium, scalingWith: .callout)))
                        .foregroundStyle(Color(AppTheme.colorForStyle(.primaryText01)))
                        .lineLimit(1)
                    Text(count == 1 ? L10n.playlistCountSingular : L10n.playlistCountPluralFormat(count.localized()))
                        .font(Font(UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)))
                        .foregroundStyle(Color(AppTheme.colorForStyle(.primaryText02)))
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .margins(.vertical, 12)
        .margins(.leading, 16)
        // Applying a content configuration rebuilds the hierarchy over the separator.
        bringSubviewToFront(separatorView)
        accessibilityLabel = "\(folder.name) \(L10n.folder)"
    }

    func hideSeparator(_ hidden: Bool) {
        separatorView.isHidden = hidden
    }

    override func handleThemeDidChange() {
        separatorView.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
    }
}
