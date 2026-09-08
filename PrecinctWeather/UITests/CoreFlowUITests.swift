import XCTest
import CoreLocation

final class CoreFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNativeOnboardingPrototypeUsesRealSearchAndProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingPrototype", "-prototypeOnboardingComplete", "NO",
                               "-disableLocation", "-hapticsEnabled", "NO", "-defaultState", "NY"]
        app.launch()
        XCTAssertTrue(app.buttons["Find a place"].waitForExistence(timeout: 15))
        capturePrototype(app, "native-welcome")
        app.buttons["How to add a widget"].tap()
        XCTAssertTrue(app.staticTexts["Add a Home Screen widget"].waitForExistence(timeout: 5))
        capturePrototype(app, "native-widget-guide")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Find a place"].waitForExistence(timeout: 5))
        app.buttons["Find a place"].tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Times Square'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertFalse(app.buttons["Find a place"].exists)
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 15))
        capturePrototype(app, "native-real-precinct")
        app.terminate()
        app.launchArguments = ["-onboardingPrototype", "-disableLocation", "-defaultState", "NY"]
        app.launch()
        XCTAssertTrue(app.buttons["Search addresses and places"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Find a place"].exists)
    }

    func testNativeOnboardingLargeTextActionsRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingPrototype", "-prototypeOnboardingComplete", "NO",
                               "-appearanceMode", "dark", "-defaultState", "NY",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let explore = app.buttons["Explore the map first"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        for _ in 0..<10 where !explore.isHittable { app.swipeUp() }
        XCTAssertTrue(explore.isHittable)
        capturePrototype(app, "native-large-text-actions")
        explore.tap()
        XCTAssertFalse(app.buttons["Find a place"].exists)
    }

    private func capturePrototype(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertEqual(footer.label, "2020 presidential vote. Demographics use the 2020 Census and ACS.")
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

        let start = app.buttons["Start reading"]
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
        XCTAssertFalse(app.buttons["Start reading"].exists, "Onboarding appeared again for a returning reader")
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
        app.buttons["Done"].tap()
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
        app.buttons["Done"].tap()
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
        app.buttons["Done"].tap()
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
