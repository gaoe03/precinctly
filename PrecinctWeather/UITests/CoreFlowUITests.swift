import XCTest
import CoreLocation

final class CoreFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLocationFollowsMovementUntilManualExplorationThenLocateResumes() {
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 40.758, longitude: -73.985))
        defer { XCUIDevice.shared.location = nil }
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-defaultState", "NY"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        allow.tap()
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 20))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.30))
        start.press(forDuration: 0.1, thenDragTo: end)
        let explore = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Explore map'"),
                                                object: app.buttons["Locate me"])
        XCTAssertEqual(XCTWaiter.wait(for: [explore], timeout: 5), .completed)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 40.7583, longitude: -73.985))
        let dot = app.descendants(matching: .any).matching(identifier: "Current location").firstMatch
        let dotMoved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '40.7583'"), object: dot)
        XCTAssertEqual(XCTWaiter.wait(for: [dotMoved], timeout: 15), .completed,
                       "The You dot stopped updating after dragging the map")
        app.buttons["Locate me"].tap()

        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 39.739, longitude: -104.990))
        XCTAssertTrue(app.buttons["Switch coverage area, currently Colorado"].waitForExistence(timeout: 20),
                      "Moving to a new precinct should update without pressing Locate")

        app.buttons["Switch coverage area, currently Colorado"].tap()
        app.buttons["California"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Switch coverage area, currently California"].waitForExistence(timeout: 10))
        let manualProfile = hero(in: app).label
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 45.515, longitude: -122.678))
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.buttons["Switch coverage area, currently Oregon"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .timedOut,
                       "A location update interrupted manual exploration")
        XCTAssertEqual(hero(in: app).label, manualProfile)
        app.buttons["Locate me"].tap()
        XCTAssertTrue(app.buttons["Switch coverage area, currently Oregon"].waitForExistence(timeout: 20))
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 40.758, longitude: -73.985))
        XCTAssertTrue(app.buttons["Switch coverage area, currently New York"].waitForExistence(timeout: 20),
                      "Locate should resume following subsequent movement")
    }

    func testCardFooterDisplaysElectionYearWithoutNumberGrouping() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "OR", "-testUnitID", "41001-:-0001"]
        app.launch()
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 15))
        app.buttons["Expand panel"].tap()
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'presidential vote. Demographics'")).firstMatch
        for _ in 0..<6 where !footer.isHittable { app.swipeUp() }
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(footer.label, "2020 presidential vote. Demographics use the 2020 Census and the American Community Survey.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "election-year-footer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testOnboardingPrecedesPermissionAndStaysDismissedAfterRelaunch() {
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-hasOnboarded", "NO", "-hapticsEnabled", "NO", "-defaultState", "NY"]
        app.launch()

        // Skipping the tour asks for location the usual way. The tour's own Locate step is
        // covered in OnboardingTourUITests.
        let start = app.buttons["Skip the tour"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.isHittable)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Location permission covered the introduction")
        XCTAssertFalse(app.buttons["Search addresses and places"].isHittable)
        start.tap()

        let deny = springboard.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Don't Allow", "Don’t Allow")
        ).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 10), "Permission was not requested after the introduction")
        deny.tap()
        let dismissDenied = app.alerts.buttons["Not Now"]
        if dismissDenied.waitForExistence(timeout: 3) { dismissDenied.tap() }
        XCTAssertTrue(app.buttons["Search addresses and places"].waitForExistence(timeout: 10))

        // Remove the argument override so the second launch checks the value actually saved.
        app.terminate()
        app.launchArguments = ["-hapticsEnabled", "NO", "-defaultState", "NY", "-disableLocation"]
        app.launch()
        XCTAssertTrue(app.buttons["Search addresses and places"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Show me around"].exists, "Onboarding appeared again for a returning reader")
        app.buttons["Search addresses and places"].tap()
        let popular = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Times Square'")).firstMatch
        XCTAssertTrue(popular.waitForExistence(timeout: 5))
        popular.tap()
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 15), "Exploration stopped working after declining location")
    }

    func testDefaultCoverageAndAppearancePersistAcrossColdLaunch() {
        let app = XCUIApplication()
        // These preferences must be written through Settings, without launch overrides.
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation"]
        app.launch()
        openSettings(app)
        chooseDefaultCoverage("Oregon", in: app)
        app.buttons["Dark appearance"].tap()
        XCTAssertTrue(app.buttons["Dark appearance"].isSelected)
        app.buttons["Close"].firstMatch.tap()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["Switch coverage area, currently Oregon"].waitForExistence(timeout: 15))
        openSettings(app)
        XCTAssertTrue(app.buttons["Dark appearance"].isSelected, "Appearance did not survive a cold launch")
        XCTAssertTrue(defaultCoveragePicker(in: app).label.contains("Oregon"))
        app.buttons["Light appearance"].tap()
        XCTAssertTrue(app.buttons["Light appearance"].isSelected)
        app.buttons["Auto appearance"].tap()
        XCTAssertTrue(app.buttons["Auto appearance"].isSelected)
        chooseDefaultCoverage("New York", in: app)
        app.buttons["Close"].firstMatch.tap()
    }

    func testDismissedSearchPreservesSelectionAndCanBeReopened() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "NY", "-testUnitID", "36081-:-36081001320"]
        app.launch()
        let profile = hero(in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        let originalProfile = profile.label
        app.buttons["Search addresses and places"].tap()
        XCTAssertTrue(app.searchFields["Address or place"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.label, originalProfile)

        app.buttons["Search addresses and places"].tap()
        let popular = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Times Square'")).firstMatch
        XCTAssertTrue(popular.waitForExistence(timeout: 5))
        popular.tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        XCTAssertNotEqual(profile.label, originalProfile, "Reopened search failed to replace the old profile")
        XCTAssertTrue(app.buttons["Switch coverage area, currently New York"].exists)
    }

    /// At peek a tap on the lean block expands the card. Once the card is open, the same block
    /// opens By the Numbers at the lean chart, and each stat opens its own chart.
    /// A bar lists its precincts highest first. The sort chip flips the list, so the bottom of
    /// "Under 20%" (0%) is one tap away instead of hundreds of rows down.
    func testSortChipReachesTheBottomOfABar() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-defaultState", "NY",
                               "-disableLocation", "-liveByNumbers", "-openDetail", "college", "-exploreBucket", "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Under 20% precincts"].waitForExistence(timeout: 20), "the bar did not open")
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort, currently'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("Highest first"), chip.label)
        let row = { (value: String) in
            app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(\\d+, )?Precinct .+, \(value)")).firstMatch
        }
        XCTAssertTrue(row("19%").waitForExistence(timeout: 10), "highest first should open on 19%")
        chip.tap()
        app.buttons["Lowest first"].tap()
        XCTAssertTrue(row("0%").waitForExistence(timeout: 10), "lowest first did not reach 0%")
        XCTAssertTrue(chip.label.contains("Lowest first"), chip.label)
    }

    func testCardLeanAndStatsOpenTheirCharts() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "OR", "-testUnitID", "41001-:-0001", "-appearanceMode", "light"]
        app.launch()
        let lean = hero(in: app)
        XCTAssertTrue(lean.waitForExistence(timeout: 15))
        // The page scrolls to the chart, past its own title, so wait on its toolbar button.
        let numbers = app.buttons["About this data"]

        // Peek: the hero is not a link. A tap expands the card and does not open By the Numbers.
        XCTAssertTrue(app.buttons["Expand panel"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Political lean'")).firstMatch.exists,
                       "The peek hero is a By the Numbers link")
        lean.tap()
        XCTAssertTrue(app.buttons["Collapse panel"].waitForExistence(timeout: 5), "A tap on the peek hero did not expand the card")
        XCTAssertFalse(numbers.waitForExistence(timeout: 2), "A tap on the peek hero opened By the Numbers")
        attach(app, "20-peek-tap-expands")

        // Open card: the lean block is a link to the lean chart.
        let leanLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Political lean R+45'")).firstMatch
        XCTAssertTrue(leanLink.waitForExistence(timeout: 5), "The open card's lean block is not a button")
        attach(app, "21-expanded-card")
        leanLink.tap()
        XCTAssertTrue(numbers.waitForExistence(timeout: 10), "The lean block did not open By the Numbers")
        assertChartAtTop(app, "How precincts lean")
        attach(app, "22-lean-chart")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(waitForGone(numbers))

        // A stat opens its own chart.
        let income = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Median income'")).firstMatch
        for _ in 0..<6 where !income.isHittable { app.swipeUp() }
        XCTAssertTrue(income.isHittable, "Median income could not be reached")
        income.tap()
        XCTAssertTrue(numbers.waitForExistence(timeout: 10), "Median income did not open By the Numbers")
        assertChartAtTop(app, "Median household income")
        attach(app, "23-income-chart")
    }

    /// The chart heading sits near the top of By the Numbers, so the page scrolled to it.
    private func assertChartAtTop(_ app: XCUIApplication, _ heading: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let header = app.staticTexts[heading].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "\(heading) is missing", file: file, line: line)
        // The page scrolls twice: once at once, then again after the list lays out.
        sleep(2)
        XCTAssertTrue(header.isHittable, "\(heading) is not on screen", file: file, line: line)
        XCTAssertLessThan(header.frame.minY, app.frame.height * 0.3,
                          "By the Numbers did not scroll to \(heading): \(header.frame)", file: file, line: line)
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                       timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func hero(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func chooseDefaultCoverage(_ name: String, in app: XCUIApplication) {
        let picker = defaultCoveragePicker(in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func defaultCoveragePicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default coverage area,'")).firstMatch
    }
}
