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
/// PNGs land in ~/Library/Caches/tools.fastlane/screenshots, prefixed with the device name.
///
/// Captures: session-chooser, session-in-up-next, switch-session, playlist-play-as-session,
/// smart-rules, smart-rule-folders, session-settings.
///
/// The simulator must already have a library with sessions in it — the shots are of real
/// data, and nothing here creates any. Seed it by installing the app and copying a populated
/// container (Documents, Library/Application Support/Pocket Casts, and the preferences plist)
/// before running, or subscribe by hand; `GenerateScreenshots.setupSubscriptions()` shows the
/// promo-list route if you only need podcasts and no sessions.
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

    /// Tap a full-width list row by label. `element(labeled:)` takes the first match in the
    /// tree, which is often a zero-size icon or an off-screen twin; a row is the widest of
    /// the matches, so pick that one.
    private func tapRow(labeled label: String) -> Bool {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", label))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.width > 100 && $0.frame.minY > 0 }
        guard let row = matches.max(by: { $0.frame.width < $1.frame.width }) else { return false }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Coordinate-based tap — works on elements XCUITest reports as not hittable
    /// (SwiftUI list rows, tip-covered content).
    private func tap(_ label: String) {
        let el = element(labeled: label)
        XCTAssert(el.waitForExistence(timeout: 10), "Missing element: \(label)")
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Tab bar order (MainTabBarController.pcTabs): Inbox, Podcasts, Playlists,
    /// Up Next/Session, Profile. The fourth item's title flips between "Up Next" and
    /// "Session" depending on whether a session owns playback, so index it, don't label it.
    private enum ForkTab: Int {
        case inbox = 0
        case podcasts
        case playlists
        case upNext
        case profile
    }

    private func select(_ tab: ForkTab) {
        app.tabBars.firstMatch.buttons.element(boundBy: tab.rawValue).waitForThenTap()
    }

    /// The Up Next screen's session title row sits just under the sticky world switcher and
    /// carries the breadcrumb tap that walks the lineup back up to the chooser. The label's
    /// text is the session's own name, so measure down from the switcher rather than query it.
    private func tapSessionBreadcrumb() {
        let switcher = app.segmentedControls.firstMatch
        guard switcher.waitForExistence(timeout: 10) else { return }
        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 50))
            .tap()
        sleep(2)
    }

    /// Show the Session side of the Up Next tab at its top (chooser) level.
    private func showSessionChooser() {
        select(.upNext)
        sleep(2)
        let sessionSegment = app.segmentedControls.firstMatch.buttons.element(boundBy: 1)
        if sessionSegment.waitForExistence(timeout: 10) {
            sessionSegment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(2)
        }
        // An active session opens straight into its lineup — step back up to the chooser.
        let chooserTitle = app.staticTexts["Sessions"]
        if !chooserTitle.waitForExistence(timeout: 3) {
            tapSessionBreadcrumb()
        }
        XCTAssert(chooserTitle.waitForExistence(timeout: 10), "Session chooser did not appear")
        sleep(3) // let the table settle so the shot isn't caught mid-reload
    }

    /// Open a smart playlist from the Playlists tab. Library contents differ per simulator,
    /// so try the stock smart playlists first and otherwise take the first row that isn't
    /// the Inbox (which is a manual playlist and has no Play Session button).
    private func openSmartPlaylist() {
        for name in ["Starred", "In Progress", "New Releases"] {
            let row = element(labeled: name)
            if row.exists {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
        }
        let rows = app.cells.allElementsBoundByIndex
        for row in rows where row.exists && !row.label.hasPrefix("Inbox") {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        XCTFail("No playlist to open on the Playlists tab")
    }

    func testForkScreenshots() throws {
        sleep(5) // give the cold launch time to open the database and warm caches
        dismissAnySheet()

        // 1 + 2. The Session side of the Up Next tab: the chooser, then a session's lineup.
        showSessionChooser()
        snapshot("session-chooser")

        // Opening a chooser row swaps the table in place — the chooser's "Sessions" title
        // going away is the only signal that the lineup is up.
        let chooserTitle = app.staticTexts["Sessions"]
        for index in 0 ..< 3 where chooserTitle.exists {
            let row = app.cells.element(boundBy: index)
            guard row.exists else { continue }
            row.tap()
            sleep(3)
        }
        XCTAssertFalse(chooserTitle.exists, "Tapping a chooser row did not open a lineup")
        sleep(2)
        snapshot("session-in-up-next")

        // 3. The Switch Session sheet, off the Up Next tab's left nav button.
        let switchButton = app.navigationBars.buttons["Switch"]
        XCTAssert(switchButton.waitForExistence(timeout: 10), "Missing Switch button")
        switchButton.tap()
        sleep(2)
        snapshot("switch-session")
        app.swipeDown(velocity: .fast)
        sleep(2)

        // 4. A smart playlist page: the Episodes | Session tabs and the Play Session button.
        // Don't dismiss tips here — a blind tap near the top of the Playlists tab opens
        // whatever playlist happens to sit under it.
        select(.playlists)
        sleep(3)
        openSmartPlaylist()
        let loadedCount = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' episodes' AND NOT label CONTAINS '0 episodes'")).firstMatch
        _ = loadedCount.waitForExistence(timeout: 30)
        XCTAssert(app.buttons["Play Session"].waitForExistence(timeout: 15), "Playlist page has no Play Session button")
        sleep(3)
        snapshot("playlist-play-as-session")

        // 5. Smart rules, then the podcast picker with its folders section.
        tap("Smart rules")
        sleep(3)
        snapshot("smart-rules")
        XCTAssert(tapRow(labeled: "Podcasts"), "No Podcasts rule row")
        sleep(3)
        XCTAssert(app.staticTexts["Choose podcasts"].waitForExistence(timeout: 10), "Podcast picker did not open")
        sleep(2)
        snapshot("smart-rule-folders")

        // The rules sheet stacks two modals over a pushed playlist page; relaunching is a
        // far more reliable way back to the tab bar than unwinding it.
        app.terminate()
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 15))
        sleep(6)
        dismissAnySheet()

        // 6. A podcast's settings page: the Inbox / Up Next / Session blocks.
        select(.podcasts)
        sleep(3)
        let firstPodcast = app.collectionViews.cells.element(boundBy: 0)
        XCTAssert(firstPodcast.waitForExistence(timeout: 15), "No podcasts on the Podcasts tab")
        firstPodcast.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(3)
        let gear = app.buttons["Settings"]
        XCTAssert(gear.waitForExistence(timeout: 10), "Missing podcast settings gear")
        gear.tap()
        sleep(3)
        // The Session block sits below Inbox and Up Next; scroll it into frame.
        if !app.staticTexts["Session Linking"].exists {
            app.swipeUp()
            sleep(2)
        }
        snapshot("session-settings")
    }
}
