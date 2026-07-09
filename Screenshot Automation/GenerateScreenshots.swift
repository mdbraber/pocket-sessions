import XCTest

enum Config {
    static let promoListUUID = "297172b7-948b-4da2-9b0d-7ae9b9068125"
    static let promoList = "pktc://sharelist/lists.pocketcasts.com/\(promoListUUID)"
}

class GenerateScreenshots: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    enum Tab: Int {
        case podcasts = 0
        case filters
        case discover
        case profile
    }

    let app = XCUIApplication()
    lazy var safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    override func setUpWithError() throws {
        continueAfterFailure = false
        setupSnapshot(app)
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 5))

        // Setup Podcast Subscription
        if requiresSetup() {
            setupSubscriptions()
        }
    }
}

// MARK: - Helpers

extension GenerateScreenshots {
    var hittablePlayButton: XCUIElement {
        return app.buttons.containing(.button, identifier: "play pause button").allElementsBoundByIndex.first(where: { $0.isHittable && $0.exists })!
    }

    var backButton: XCUIElement {
        return app.navigationBars.buttons.element(boundBy: 0)
    }

    func requiresSetup() -> Bool {
        selectTab(.podcasts)
        return app.buttons["Discover Podcasts"].exists
    }

    func setupSubscriptions() {
        // Setup Podcast subscription
        safari.launch()
        XCTAssert(safari.wait(for: .runningForeground, timeout: 5))
        safariLoad(url: Config.promoList)
        safari.buttons["Open"].waitForThenTap()

        XCTAssert(app.wait(for: .runningForeground, timeout: 5))
        app.buttons["SUBSCRIBE TO ALL"].waitForThenTap()
        app.buttons["action_0"].waitForThenTap()
    }

    func safariLoad(url: String) {
        // Setup Podcast subscription
        safari.descendants(matching: .any)["Address"].waitForThenTap()
        safari.typeText(url)
        safari.buttons["Go"].tap()
    }

    func selectTab(_ tab: Tab) {
        app.tabBars.firstMatch.buttons.element(boundBy: tab.rawValue).waitForThenTap()
    }

    func openEpisode(_ key: String) {
        app.cells.containing(NSPredicate(format: "label CONTAINS '\(key)'")).firstMatch.waitForThenTap()
    }

    func navigateToApperance() {
        selectTab(.profile)
        app.buttons["Settings"].waitForThenTap()
        app.staticTexts["appearance"].waitForThenTap()
    }

    func enableSystemThemeMatching() {
        let systemThemeToggle = app.switches["system theme toggle"]
        systemThemeToggle.expectExistence()
        if let value = systemThemeToggle.value as? String, value == "0" {
            systemThemeToggle.tap()
        }
    }

    func scrollToAndTap(_ element: XCUIElement) {
        let initialScrollPercent = app.collectionViews.scrollPercent()
        var traversedDown = initialScrollPercent == 100
        var traversedUp = initialScrollPercent == 0
        while !element.isHittable {
            if !traversedDown {
                app.swipeUp()
                traversedDown = app.collectionViews.scrollPercent() == 100
            } else if !traversedUp {
                app.swipeDown()
                traversedUp = app.collectionViews.scrollPercent() == 0
            } else {
                break
            }
        }

        element.tap()
    }
}

// MARK: - Fork screenshots

/// Fork: captures the README screenshots (docs/fork/) on the simulator so they all
/// share the same device frame and data. Run against the booted simulator with:
///   xcodebuild test -project podcasts.xcodeproj -scheme "Screenshot Automation" \
///     -configuration StagingDebug -destination "platform=iOS Simulator,id=booted" \
///     -only-testing:"Screenshot Automation/ForkScreenshots"
/// PNGs land in ~/Library/Caches/tools.fastlane/screenshots.
final class ForkScreenshots: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        setupSnapshot(app)
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 10))
    }

    private func element(labeled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] %@", label)).firstMatch
    }

    private func dismissAnySheet() {
        for label in ["Close", "Not Now", "Maybe Later", "Done"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                sleep(1)
            }
        }
    }

    /// TipKit bubbles (e.g. "Reorder your playlists") block hit-testing; a tap on the
    /// navigation bar area dismisses them without activating anything.
    private func dismissTips() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
    }

    /// Coordinate-based tap — works on elements XCUITest reports as not hittable
    /// (SwiftUI list rows, tip-covered content).
    private func tap(_ label: String) {
        let el = element(labeled: label)
        XCTAssert(el.waitForExistence(timeout: 10), "Missing element: \(label)")
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testForkScreenshots() throws {
        let tabBar = app.tabBars.firstMatch
        sleep(5) // give the cold launch time to open the database and warm caches
        dismissAnySheet()

        // Starred playlist page with the Play as Session pill.
        tabBar.buttons.element(boundBy: 1).waitForThenTap() // Playlists
        sleep(2)
        dismissTips()
        tap("Starred")
        // The episode list loads asynchronously — wait for a non-zero count before
        // trusting the page (Play as Session no-ops on an empty list).
        let loadedCount = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' episodes' AND NOT label CONTAINS '0 episodes'")).firstMatch
        _ = loadedCount.waitForExistence(timeout: 30)
        sleep(2)
        snapshot("playlist-play-as-session")

        // Start the session on Starred.
        tap("Play as Session")
        // Custom-order playlists with an empty Lineup ask before playing.
        let playAsIs = app.buttons["Play as-is"]
        if playAsIs.waitForExistence(timeout: 2) {
            playAsIs.tap()
        }
        sleep(3)

        // Session view on the Up Next screen.
        tabBar.buttons.element(boundBy: 3).waitForThenTap() // Session / Up Next
        sleep(2)
        snapshot("session-in-up-next")

        // Peek at the queue and open the filter picker. The pill switcher is not
        // exposed as a segmented control, so find the segment by its label.
        tap("Up Next ·")
        sleep(1)
        tap("Filter Up Next By")
        sleep(2)
        snapshot("up-next-filter")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() // dismiss picker
        sleep(1)

        // Smart rules editor, then the folder rule picker — last, since the sheet
        // has no swipe-to-dismiss and the test can end with it open.
        tabBar.buttons.element(boundBy: 1).waitForThenTap()
        sleep(1)
        tap("Starred")
        _ = loadedCount.waitForExistence(timeout: 30)
        sleep(2)
        tap("Smart rules")
        sleep(2)
        snapshot("smart-rules")
        let foldersRow = element(labeled: "Folders")
        if foldersRow.waitForExistence(timeout: 3) {
            foldersRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(2)
            snapshot("smart-rule-folders")
        }
    }
}
