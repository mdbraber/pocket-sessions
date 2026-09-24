import Combine
import UIKit
import SwiftUI
import PocketCastsDataModel
import PocketCastsUtils

class NewPlaylistCell: ThemeableCell {
    typealias NewPlaylistCellType = NewPlaylistCellViewModel.DisplayType

    let playlistMetadataLoader = PlaylistMetadataLoader.shared

    lazy var artworkImageSource: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    static let reuseIdentifier = "PlaylistCell"
    static let cellHeight = 81.0
    static let emptyPlaylist = EpisodeFilter()

    lazy var separatorView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private var viewModel = NewPlaylistCellViewModel()
    private var playlistCountLoadTask: Task<Void, Never>?
    private var playlistImageLoadTask: Task<Void, Never>?
    private var playlistID: String = ""
    private var cancellables = Set<AnyCancellable>()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        // Fork: chevrons mark folders only — playlist rows go without.
        accessoryType = .none

        self.style = .primaryUi02
        iconStyle = .primaryIcon02

        updateColor()

        separatorView.backgroundColor = AppTheme.colorForStyle(.primaryUi05)

        separatorInset = UIEdgeInsets(top: 0, left: .greatestFiniteMagnitude, bottom: 0, right: 0)
        layoutMargins = .zero
        preservesSuperviewLayoutMargins = false

        self.contentConfiguration = UIHostingConfiguration {
            NewPlaylistCellView(viewModel: viewModel)
                .environmentObject(Theme.sharedTheme)
        }
        .margins(.vertical, 12)
        // Symmetric row insets — the trailing side matches the leading 16.
        .margins(.horizontal, 16)

        addSubview(artworkImageSource)
        addSubview(separatorView)
        bringSubviewToFront(separatorView)
        NSLayoutConstraint.activate([
            artworkImageSource.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 16.0),
            artworkImageSource.widthAnchor.constraint(equalToConstant: 56.0),
            artworkImageSource.heightAnchor.constraint(equalToConstant: 56.0),
            artworkImageSource.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1.0)
        ])
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        ensureCorrectReorderColor()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        ensureCorrectReorderColor()
    }

    private func ensureCorrectReorderColor() {
        let theme = themeOverride ?? Theme.sharedTheme.activeTheme

        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    }

    override func updateColor() {
        super.updateColor()
        separatorView.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        viewModel.playlistName = ""
        viewModel.isSmartPlaylist = false
        viewModel.episodesCount = 0
        viewModel.images = []
        viewModel.displayType = .count
        viewModel.badgeType = .off
        viewModel.badgeCount = 0
        playlistCountLoadTask?.cancel()
        playlistCountLoadTask = nil
        playlistImageLoadTask?.cancel()
        playlistImageLoadTask = nil
        if FeatureFlag.playlistCacheInvalidation.enabled {
            cancellables.removeAll()
        }
        Task {
            await playlistMetadataLoader.cancelLoadCount(for: playlistID)
            await playlistMetadataLoader.cancelLoadImages(for: playlistID)
        }
    }

    /// Fork: the Switch Session sheet's "Up Next" row — identical layout to a playlist
    /// row, with the up-next glyph on the artwork tile and the queue count trailing.
    func configureUpNext(title: String = L10n.upNext, episodeCount: Int) {
        reset()
        viewModel.playlistName = title
        viewModel.displayType = .upNext
        viewModel.episodesCount = episodeCount
    }

    /// Fork: subtitle for session stores ("Session playlist · fed from ...").
    func setSessionSubtitle(_ subtitle: String?) {
        viewModel.sessionSubtitle = subtitle
    }

    func set(playlistName: String, isManualPlaylist: Bool) {
        viewModel.playlistName = playlistName
        viewModel.isSmartPlaylist = !isManualPlaylist
    }

    func loadMetadata(for playlist: EpisodeFilter) {
        playlistID = playlist.uuid

        // Fork: the row badge (replaces the plain count when a type is chosen).
        let badgeType = Settings.playlistsBadgeType()
        viewModel.badgeType = badgeType
        if badgeType != .off {
            Task { [weak self] in
                guard let self else { return }
                let loadingPlaylist = playlistID
                let count = SessionFeederEngine.badgeCount(forPlaylist: playlist, badgeType: badgeType)
                guard self.playlistID == loadingPlaylist else { return }
                await MainActor.run {
                    if count != self.viewModel.badgeCount {
                        self.viewModel.badgeCount = count
                    }
                }
            }
        }

        // Cancel previous subscriptions and set up new ones for this playlist
        if FeatureFlag.playlistCacheInvalidation.enabled {
            cancellables.removeAll()
            subscribeToUpdates(for: playlist.uuid)
        }

        playlistCountLoadTask = Task { [weak self] in
            guard let self else { return }
            let loadingPlaylist = playlistID

            if FeatureFlag.playlistDataCacheBeforeQuery.enabled {
                if let cachedCount = await self.playlistMetadataLoader.cachedCount(for: playlist.uuid) {
                    await MainActor.run {
                        self.viewModel.episodesCount = cachedCount
                    }
                }
            }

            let count = await self.playlistMetadataLoader.loadCount(for: playlist)
            if self.playlistID != loadingPlaylist {
                return
            }
            await MainActor.run {
                if count != self.viewModel.episodesCount {
                    self.viewModel.episodesCount = count
                }
            }
        }
        playlistImageLoadTask = Task { [weak self] in
            guard let self else { return }
            let loadingPlaylist = playlistID

            if FeatureFlag.playlistDataCacheBeforeQuery.enabled {
                if let cachedImages = await self.playlistMetadataLoader.cachedImages(for: playlist.uuid) {
                    self.viewModel.images = cachedImages
                }
            }

            let images = await self.playlistMetadataLoader.loadImages(for: playlist)
            if self.playlistID != loadingPlaylist {
                return
            }
            await MainActor.run {
                if images != self.viewModel.images {
                    self.viewModel.images = images
                }
            }
        }
    }

    /// Subscribe to metadata updates for the specified playlist.
    /// This enables reactive updates when counts or images change from other sources.
    private func subscribeToUpdates(for playlistID: String) {
        // Subscribe to count updates
        playlistMetadataLoader.countUpdatesPublisher
            .filter { $0.playlistID == playlistID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self, self.playlistID == playlistID else { return }
                if update.count != self.viewModel.episodesCount {
                    self.viewModel.episodesCount = update.count
                }
            }
            .store(in: &cancellables)

        // Subscribe to image updates
        playlistMetadataLoader.imageUpdatesPublisher
            .filter { $0.playlistID == playlistID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self, self.playlistID == playlistID else { return }
                if update.images != self.viewModel.images {
                    self.viewModel.images = update.images
                }
            }
            .store(in: &cancellables)
    }

    func hideSeparator(_ hide: Bool) {
        separatorView.alpha = hide ? 0 : 1
    }
}
