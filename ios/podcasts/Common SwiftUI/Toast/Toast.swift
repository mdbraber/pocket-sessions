import Foundation
import UIKit

/// 🍞 Toast - A lightweight way to display informative overlay messages
///
/// Usage:
///
///     // Message only
///     Toast.show("Hello World!")
///
///     // Message with button
///     Toast.show("Hello", actions: [.init(title: "World", action: {
///          print("Hello World!")
///     })])
///
@MainActor
class Toast {
    private static let shared = Toast()

    /// Retain the visible window
    private var window: UIWindow? = nil

    /// Display the toast message with the given title and actions
    static func show<Style: ToastTheme>(_ title: String, actions: [Action]? = nil, dismissAfter: ToastViewDismissPolicy = .interval(5.0), theme: Style = .defaultTheme, aboveMiniPlayer: Bool = false) {
        // Hide any active toasts
        shared.toastDismissed()

        guard let scene = SceneHelper.connectedScene() else { return }

        let viewModel = ToastViewModel(coordinator: shared, title: title, actions: actions, dismissPolicy: dismissAfter, aboveMiniPlayer: aboveMiniPlayer)
        viewModel.bottomInset = bottomObstruction(in: scene)
        let view = ToastView(viewModel: viewModel, style: theme)
        let controller = ThemedHostingController(rootView: view)

        let window = ToastWindow(windowScene: scene, viewModel: viewModel, controller: controller)
        window.makeKeyAndVisible()

        shared.window = window
    }

    /// Fork: how far above the bottom safe area the toast has to sit to clear the tab bar and
    /// the mini player, so it never covers them. Zero while a modal (the full-screen player, a
    /// sheet) is up, since that hides both.
    private static func bottomObstruction(in scene: UIWindowScene) -> CGFloat {
        guard let window = scene.windows.first(where: { !($0 is ToastWindow) && $0.rootViewController is UITabBarController }),
              let tabBarController = window.rootViewController as? UITabBarController,
              tabBarController.presentedViewController == nil else { return 0 }
        var top = window.bounds.maxY
        let tabBar = tabBarController.tabBar
        if !tabBar.isHidden, tabBar.alpha > 0.01 {
            top = min(top, tabBar.convert(tabBar.bounds, to: window).minY)
        }
        if let miniPlayer = (UIApplication.shared.delegate as? AppDelegate)?.miniPlayer()?.view, miniPlayer.window == window, !miniPlayer.isHidden {
            top = min(top, miniPlayer.convert(miniPlayer.bounds, to: window).minY)
        }
        return max(0, window.bounds.maxY - top - window.safeAreaInsets.bottom)
    }

    /// Dismisses any visible toasts
    static func dismiss() {
        shared.window?.resignKey()
        shared.window = nil
    }

    struct Action: Identifiable {
        let title: String
        let action: @MainActor () -> Void

        var id: String { title }
    }
}

// MARK: - ToastCoordinator

extension Toast: ToastDelegate {
    func toastDismissed() {
        Self.dismiss()
    }
}

// MARK: - ToastWindow

/// This is a UIWindow subclass that allows passthrough events but also interaction with our SwiftUI toast view
/// The window overrides hitTest which asks the view model if the event point is within the view
private class ToastWindow: UIWindow {
    private weak var viewModel: ToastViewModel?

    init(windowScene: UIWindowScene, viewModel: ToastViewModel, controller: UIViewController) {
        self.viewModel = viewModel

        super.init(windowScene: windowScene)

        controller.view.backgroundColor = .clear
        rootViewController = controller
        windowLevel = .alert
        backgroundColor = .clear
    }

    // MARK: - Overridden

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        viewModel?.hitTest(point) ?? false ? super.hitTest(point, with: event) : nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
