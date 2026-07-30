import XCTest
@testable import podcasts

/// Fork: regression cover for a bug that cost a lot to find.
///
/// `PCSearchBarController.xib` gives the Cancel button no height of its own. Its height falls out of
/// two constraints — a required `centerY` tie to the search field, and a 999-priority
/// `superview.bottom == cancelButton.bottom + 16`. Both are satisfiable at ANY height, so a host
/// that constrains the controller's root view shorter than the XIB's natural size doesn't break a
/// constraint or log a warning: the button silently squashes. At a 36pt root it collapsed to 4pt
/// tall while its title kept drawing at full size, so "Cancel" looked completely normal and was
/// almost impossible to tap.
final class SearchBarCancelButtonTests: XCTestCase {

    /// Lays the controller out inside a host of `height`, exactly as an embedding screen does.
    ///
    /// `pillHeight` mirrors the hosts that also pin `roundedBackgroundView` (the Queue pins it to
    /// 36 so the field is a fixed size rather than the XIB's two-thirds-of-the-root rule). The
    /// button is centred on the pill, so where the pill sits decides where the button sits.
    private func layOut(rootHeight height: CGFloat, pillHeight: CGFloat? = nil) -> PCSearchBarController {
        let controller = PCSearchBarController()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        let search = controller.view!
        search.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(search)
        var constraints = [
            search.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            search.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: height)
        ]
        if let pillHeight {
            constraints.append(controller.roundedBackgroundView.heightAnchor.constraint(equalToConstant: pillHeight))
        }
        NSLayoutConstraint.activate(constraints)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return controller
    }

    /// The Queue world constrains the root to 36pt. That is the case that broke.
    func testCancelButtonStaysTappableInAShortHost() {
        let controller = layOut(rootHeight: 36)
        XCTAssertGreaterThanOrEqual(controller.cancelButton.bounds.height, 30,
                                    "Cancel collapsed to \(controller.cancelButton.bounds.height)pt — it renders fine but can't be tapped")
    }

    /// The playlist page uses 56pt; the Inbox uses `defaultHeight`. Neither should regress.
    func testCancelButtonHasUsableHeightAtEveryHostSizeWeShip() {
        for height in [CGFloat(36), 48, 56, PCSearchBarController.defaultHeight] {
            let controller = layOut(rootHeight: height)
            XCTAssertGreaterThanOrEqual(controller.cancelButton.bounds.height, 30,
                                        "Cancel collapsed at a \(height)pt host")
        }
    }

    /// The button must also stay INSIDE the root view, which clips — a tall button would be
    /// visually cut off, and the part hanging outside would not receive touches either. Checked in
    /// the Queue's exact embedding (36pt root, 36pt pill), which is the tightest one we ship.
    func testCancelButtonStaysWithinTheRootViewBounds() {
        let controller = layOut(rootHeight: 36, pillHeight: 36)
        let button = controller.cancelButton!
        let frame = button.convert(button.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(frame.minY, 0, "Cancel extends above the search bar's bounds")
        XCTAssertLessThanOrEqual(frame.maxY, controller.view.bounds.height,
                                 "Cancel extends below the search bar's bounds")
    }
}
