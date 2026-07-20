import Combine
import PocketCastsDataModel
import UIKit

/// Fork: wraps the episode Sessions list as a full-screen player tab (after Chapters,
/// before Bookmarks), following the current track.
class SessionsPlayerItemViewController: PlayerItemViewController {
    private let viewModel = EpisodeSessionsViewModel()
    private let controller: ThemedHostingController<EpisodeSessionsListView>

    private var cancellables = Set<AnyCancellable>()

    init() {
        controller = ThemedHostingController(rootView: EpisodeSessionsListView(viewModel: viewModel, style: .player))
        super.init(nibName: nil, bundle: nil)

        viewModel.onOpenSession = { row in
            // Open the session's playlist on its Session (lineup) tab. Switching tabs
            // closes the full-screen player on the way.
            PlaylistDetailViewModel.pendingInitialTab[row.storeUuid] = .lineup
            NavigationManager.sharedManager.navigateTo(NavigationManager.filterPageKey, data: [NavigationManager.filterUuidKey: row.storeUuid])
        }

        viewModel.onAddToSession = { [weak self] in
            // The standard add flow; any "which session?" picker presents over the player.
            guard let self, let episode = PlaybackManager.shared.currentEpisode() as? Episode else { return }
            SessionManager.shared.addToSessions(episodeUuids: [episode.uuid], preferred: nil, presenting: self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = controller.view.map {
            let view = UIStackView(arrangedSubviews: [$0])
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = .clear
            return view
        } ?? UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(controller)
    }

    // MARK: - Player Events

    override func willBeAddedToPlayer() {
        // The player rebuilds its tabs on every track change, so this can run more
        // than once — drop stale subscriptions before adding new ones.
        cancellables.removeAll()
        updateCurrentEpisode()

        Constants.Notifications.playbackTrackChanged.publisher().sink { [weak self] _ in
            self?.updateCurrentEpisode()
        }.store(in: &cancellables)
    }

    override func willBeRemovedFromPlayer() {
        cancellables.removeAll()
        viewModel.episodeUuid = nil
    }

    private func updateCurrentEpisode() {
        viewModel.episodeUuid = (PlaybackManager.shared.currentEpisode() as? Episode)?.uuid
    }
}
