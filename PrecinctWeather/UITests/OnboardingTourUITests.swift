import XCTest

/// Drives the first-run tour with real gestures on the real map, card, search and menus, and
/// attaches a screenshot per step to the result bundle.
final class OnboardingTourUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The tour drops its Locate step when location is denied, and an earlier test may have
    /// denied it. Every launch starts from an undecided permission so each test sees six steps.
    private func launchUndecided(_ app: XCUIApplication) {
        app.resetAuthorizationStatus(for: .location)
        app.launch()
    }

    // MARK: Full tour

    func testTourLight() throws { try runFullTour(appearance: "light", largeText: false) }
    func testTourDark() throws { try runFullTour(appearance: "dark", largeText: false) }
    func testTourLargestTextDark() throws { try runFullTour(appearance: "dark", largeText: true) }

    /// Welcome, then the area, a map tap, the card, By the Numbers, search and Locate. Each step
    /// is done with the real control, and each sheet shows the tour's guide inside it.
    private func runFullTour(appearance: String, largeText: Bool) throws {
        let app = XCUIApplication()
        var arguments = ["-hapticsEnabled", "NO", "-disableLocation", "-exposeMapCamera",
                         "-defaultState", "NY", "-hasOnboarded", "NO", "-appearanceMode", appearance]
        if largeText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = arguments
        launchUndecided(app)
        let suffix = appearance + (largeText ? "-ax" : "")

        let start = app.buttons["Show me around"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Skip the tour"].exists)
        sleep(1)
        save("01-welcome", suffix)
        start.tap()

        // Coverage comes first: the real area menu, with "Keep New York" to stay.
        XCTAssertTrue(waitForCaption(app, "Start by picking the state or area you want to explore."))
        XCTAssertTrue(caption(in: app).label.contains("Step 1 of 6"), caption(in: app).label)
        XCTAssertTrue(app.buttons["Keep New York"].exists, "The coverage step does not offer to keep New York")
        sleep(1)
        save("02-coverage", suffix)
        app.buttons["Switch coverage area, currently New York"].tap()
        let california = app.buttons["California"].firstMatch
        XCTAssertTrue(california.waitForExistence(timeout: 5))
        california.tap()

        // Tap step, in California at street level.
        XCTAssertTrue(waitForCaption(app, "Tap anywhere on the map"), "Picking California did not advance the tour")
        XCTAssertTrue(caption(in: app).label.contains("Step 2 of 6"), caption(in: app).label)
        XCTAssertTrue(app.buttons["Switch coverage area, currently California"].waitForExistence(timeout: 10))
        let tapCamera = try settledCamera(app)
        XCTAssertLessThan(tapCamera.spanLat, 0.1, "The tap step opened zoomed out: \(tapCamera)")
        sleep(1)
        save("03-tap-california", suffix)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: largeText ? 0.45 : 0.42)).tap()

        // Card step: a real swipe up on the peek card, then back down.
        XCTAssertTrue(waitForCaption(app, "Swipe the card up"), "A map tap did not advance the tour")
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 10))
        sleep(1)
        save("04-card", suffix)
        let cardTop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: cardTopOffset(app)))
        cardTop.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(waitForCaption(app, "back down to return"), "Pulling the card up did not advance the tour")
        sleep(1)
        save("05-card-open", suffix)
        let handleArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.08))
        handleArea.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.8)))

        // By the Numbers: the real screen, with the tour's guide inside it. Continue closes it.
        XCTAssertTrue(waitForCaption(app, "compare every precinct"), "Pulling the card down did not advance the tour")
        sleep(1)
        save("06-numbers", suffix)
        app.buttons["By the numbers"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Each chart shows how every precinct in California compares"),
                      "By the Numbers has no tour guide")
        XCTAssertTrue(sheetGuide(in: app).label.contains("Step 4 of 6"), sheetGuide(in: app).label)
        XCTAssertTrue(app.buttons["End tour"].isHittable)
        sleep(1)
        save("07-numbers-guide", suffix)
        app.buttons["Continue"].tap()

        // Search: the real search, with its guide. A popular place finishes the step.
        XCTAssertTrue(waitForCaption(app, "find any address"), "Continue in By the Numbers did not advance the tour")
        XCTAssertFalse(app.buttons["Continue"].exists, "Continue did not close By the Numbers")
        sleep(1)
        save("08-search", suffix)
        app.buttons["Search addresses and places"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Type any address, or tap one of the popular places"), "Search has no tour guide")
        XCTAssertTrue(sheetGuide(in: app).label.contains("Step 5 of 6"), sheetGuide(in: app).label)
        sleep(1)
        save("09-search-guide", suffix)
        let place = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'San Francisco'")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        place.tap()

        // Location is optional. "Not now" ends the tour without a permission prompt.
        XCTAssertTrue(waitForCaption(app, "your own precinct"), "Picking a search result did not advance the tour")
        XCTAssertTrue(caption(in: app).label.contains("Step 6 of 6"), caption(in: app).label)
        sleep(1)
        save("10-location", suffix)
        app.buttons["Not now"].tap()

        // Normal map state: no tour, real controls, peek card with the California profile.
        XCTAssertTrue(waitForGone(caption(in: app)))
        XCTAssertTrue(app.buttons["Switch coverage area, currently California"].waitForExistence(timeout: 10))
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Expand panel"].exists, "The card is not at peek after the tour")
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Not now still raised the location prompt")
        sleep(1)
        save("11-done", suffix)
    }

    // MARK: Skip

    /// "Keep New York" moves past the area step and leaves a street-level map to tap. Every
    /// later step can be skipped.
    func testKeepAreaThenSkipEveryStepLandsOnMap() throws {
        let app = launchFresh(extra: ["-exposeMapCamera"])
        app.buttons["Show me around"].tap()
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        app.buttons["Keep New York"].tap()
        XCTAssertTrue(waitForCaption(app, "Tap anywhere on the map"), "Keep New York did not advance the tour")
        XCTAssertTrue(app.buttons["Switch coverage area, currently New York"].exists)
        let camera = try settledCamera(app)
        XCTAssertLessThan(camera.spanLat, 0.1, "The tap step opened zoomed out: \(camera)")
        save("12-keep-new-york-tap", "light")
        var skipped = 1
        while caption(in: app).waitForExistence(timeout: 5), skipped < 8 {
            let skip = app.buttons["Skip step"].exists ? app.buttons["Skip step"] : app.buttons["Not now"]
            XCTAssertTrue(skip.exists)
            skip.tap()
            skipped += 1
            sleep(1)
        }
        XCTAssertEqual(skipped, 6, "Expected six steps")
        XCTAssertFalse(caption(in: app).exists)
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)
        XCTAssertTrue(app.buttons["Expand panel"].exists)
    }

    func testSkipAllFromWelcomeAndMidTour() {
        var app = launchFresh()
        app.buttons["Skip the tour"].tap()
        XCTAssertTrue(waitForGone(app.buttons["Show me around"]))
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)

        app = launchFresh()
        app.buttons["Show me around"].tap()
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        app.buttons["Keep New York"].tap()
        XCTAssertTrue(waitForCaption(app, "Tap anywhere on the map"))
        app.buttons["Skip step"].tap()
        XCTAssertTrue(waitForCaption(app, "Swipe the card up"))
        app.buttons["End tour"].tap()
        XCTAssertTrue(waitForGone(caption(in: app)))
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)
        XCTAssertTrue(app.buttons["Expand panel"].exists)
    }

    // MARK: Guides inside sheets

    /// "End tour" inside By the Numbers closes the sheet and ends the tour.
    func testNumbersGuideEndsTour() {
        let app = launchFresh()
        advance(app, toCaption: "compare every precinct")
        app.buttons["By the numbers"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Each chart shows how every precinct in New York compares"))
        app.buttons["End tour"].tap()
        XCTAssertTrue(waitForGone(sheetGuide(in: app)))
        XCTAssertTrue(app.buttons["Search addresses and places"].waitForExistence(timeout: 5))
        XCTAssertFalse(caption(in: app).waitForExistence(timeout: 2), "The tour went on after End tour")
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable, "By the Numbers stayed open")
        save("13-numbers-end-tour", "light")
    }

    /// "Skip step" inside Search closes it and moves on to Locate. "End tour" there ends the tour.
    func testSearchGuideSkipsAndEndsTour() {
        var app = launchFresh()
        advance(app, toCaption: "find any address")
        app.buttons["Search addresses and places"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Type any address, or tap one of the popular places"))
        app.buttons["Skip step"].tap()
        XCTAssertTrue(waitForCaption(app, "your own precinct"), "Skip step in Search did not move on to Locate")
        XCTAssertFalse(app.searchFields["Address or place"].exists, "Skip step left Search open")
        save("14-search-skip", "light")

        app = launchFresh()
        advance(app, toCaption: "find any address")
        app.buttons["Search addresses and places"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Type any address, or tap one of the popular places"))
        app.buttons["End tour"].tap()
        XCTAssertTrue(waitForGone(app.searchFields["Address or place"]), "End tour left Search open")
        XCTAssertFalse(caption(in: app).waitForExistence(timeout: 2), "The tour went on after End tour")
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)
        save("15-search-end-tour", "light")
    }

    /// The dim must block the controls that are not part of the step.
    func testDimBlocksOtherControls() {
        let app = launchFresh()
        app.buttons["Show me around"].tap()
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        sleep(1)
        let settings = app.buttons["Settings"]
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2),
                       "A dimmed control opened during the coverage step")
        app.buttons["Keep New York"].tap()
        XCTAssertTrue(waitForCaption(app, "Tap anywhere on the map"))
        sleep(1)
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2),
                       "A dimmed control opened during the tap step")
        XCTAssertTrue(caption(in: app).label.contains("Tap anywhere on the map"))
    }

    /// The VoiceOver-only buttons complete every step. VoiceOver itself cannot run in a UI test,
    /// so a debug flag shows the same buttons it would.
    func testVoiceOverButtonsCompleteEveryStep() {
        let app = XCUIApplication()
        app.launchArguments = ["-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "NY", "-hasOnboarded", "NO", "-appearanceMode", "light",
                               "-tourVoiceOverActions"]
        launchUndecided(app)
        XCTAssertTrue(app.buttons["Show me around"].waitForExistence(timeout: 20))
        app.buttons["Show me around"].tap()
        // No stand-in here: the real menu is a VoiceOver element on its own.
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        app.buttons["Switch coverage area, currently New York"].tap()
        app.buttons["Oregon"].firstMatch.tap()
        XCTAssertTrue(waitForCaption(app, "Tap anywhere on the map"))
        sleep(1)
        save("16-voiceover-tap", "light")
        app.buttons["Select the precinct in the middle of the map"].tap()
        XCTAssertTrue(waitForCaption(app, "Swipe the card up"))
        app.buttons["Expand the card"].tap()
        XCTAssertTrue(waitForCaption(app, "back down to return"))
        app.buttons["Collapse the card"].tap()
        XCTAssertTrue(waitForCaption(app, "compare every precinct"))
        app.buttons["Open By the Numbers"].tap()
        // The sheet's own close button also finishes the step.
        XCTAssertTrue(waitForSheetGuide(app, "Each chart shows how every precinct in Oregon compares"))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(waitForCaption(app, "find any address"))
        app.buttons["Open search"].tap()
        XCTAssertTrue(waitForSheetGuide(app, "Type any address"))
        let place = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Portland'")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        place.tap()
        XCTAssertTrue(waitForCaption(app, "your own precinct"))
        app.buttons["Show my precinct"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Allow, so later runs still show the location step. A denial makes the tour skip it.
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(waitForGone(caption(in: app)))
        XCTAssertTrue(app.buttons["Expand panel"].waitForExistence(timeout: 5))
    }

    /// A real tap on Locate ends the tour on the location step.
    func testLocateTapEndsTour() {
        let app = launchFresh()
        advance(app, toCaption: "your own precinct")
        XCTAssertTrue(app.buttons["Not now"].exists)
        app.buttons["Locate me"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Allow, so later runs still show the location step. A denial makes the tour skip it.
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        XCTAssertTrue(waitForGone(caption(in: app)), "Locate did not end the tour")
        XCTAssertTrue(app.buttons["Search addresses and places"].isHittable)
    }

    // MARK: Replay

    func testReplayFromSettingsKeepsPreferences() {
        let app = XCUIApplication()
        // No -defaultState or -appearanceMode here: they are written through Settings.
        app.launchArguments = ["-hapticsEnabled", "NO", "-disableLocation", "-hasOnboarded", "YES"]
        app.launch()
        openSettings(app)
        chooseDefaultCoverage("Oregon", in: app)
        app.buttons["Dark appearance"].tap()
        let replay = app.buttons["Replay the tour"]
        for _ in 0..<5 where !replay.isHittable { app.swipeUp() }
        save("17-settings-replay", "dark")
        replay.tap()

        XCTAssertTrue(app.buttons["Show me around"].waitForExistence(timeout: 10))
        app.buttons["Show me around"].tap()
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        // "Keep" names the area on the map now.
        let area = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch coverage area, currently '")).firstMatch
        XCTAssertTrue(area.exists)
        let areaName = area.label.replacingOccurrences(of: "Switch coverage area, currently ", with: "")
        save("18-replay-coverage", "dark")
        XCTAssertTrue(app.buttons["Keep \(areaName)"].exists,
                      "The coverage step does not offer to keep \(areaName): \(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keep'")).firstMatch.label)")
        app.buttons["End tour"].tap()
        XCTAssertTrue(waitForGone(caption(in: app)))

        openSettings(app)
        XCTAssertTrue(app.buttons["Dark appearance"].isSelected, "Replay changed the appearance")
        XCTAssertTrue(defaultCoveragePicker(in: app).label.contains("Oregon"), "Replay changed the default area")
        chooseDefaultCoverage("New York", in: app)
        app.buttons["Auto appearance"].tap()
        app.buttons["Close"].firstMatch.tap()
    }

    // MARK: Map drag

    /// A one-finger drag must pan the camera without zooming it.
    func testMapDragPansWithoutZooming() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hapticsEnabled", "NO", "-disableLocation",
                               "-hasOnboarded", "YES", "-defaultState", "NY", "-exposeMapCamera",
                               "-testUnitID", "36081-:-36081001322"]
        app.launch()
        XCTAssertTrue(hero(in: app).waitForExistence(timeout: 15))
        let before = try settledCamera(app)

        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to)
        let afterDrag = try settledCamera(app, differentFrom: before)
        assertPanned(before, afterDrag, "slow drag")

        // A quick flick, the other way.
        let flickFrom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35))
        let flickTo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        flickFrom.press(forDuration: 0.05, thenDragTo: flickTo, withVelocity: .fast, thenHoldForDuration: 0)
        let afterFlick = try settledCamera(app, differentFrom: afterDrag)
        assertPanned(afterDrag, afterFlick, "flick")
    }

    private struct Camera: Equatable { let lat, lon, spanLat, spanLon: Double }

    private func settledCamera(_ app: XCUIApplication, differentFrom previous: Camera? = nil) throws -> Camera {
        let element = app.descendants(matching: .any)["Map camera"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        var last: Camera?
        var stableReads = 0
        for _ in 0..<40 {
            usleep(250_000)
            let parts = (element.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { continue }
            let camera = Camera(lat: parts[0], lon: parts[1], spanLat: parts[2], spanLon: parts[3])
            if camera == last, camera != previous { stableReads += 1 } else { stableReads = 0 }
            last = camera
            if stableReads >= 3 { return camera }
        }
        return try XCTUnwrap(last)
    }

    private func assertPanned(_ a: Camera, _ b: Camera, _ name: String) {
        let moved = hypot(b.lat - a.lat, b.lon - a.lon)
        XCTAssertGreaterThan(moved, a.spanLon * 0.15, "\(name) did not move the camera")
        let zoom = b.spanLat / a.spanLat
        XCTAssertEqual(zoom, 1, accuracy: 0.05, "\(name) changed the zoom by \(zoom)x")
        print("MAPDRAG \(name): moved \(moved) deg, zoom ratio \(zoom), before \(a), after \(b)")
    }

    // MARK: Helpers

    private func launchFresh(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "NY", "-hasOnboarded", "NO", "-appearanceMode", "light"] + extra
        launchUndecided(app)
        XCTAssertTrue(app.buttons["Show me around"].waitForExistence(timeout: 20))
        return app
    }

    /// Starts the tour and skips steps until the caption shows `text`.
    private func advance(_ app: XCUIApplication, toCaption text: String) {
        app.buttons["Show me around"].tap()
        XCTAssertTrue(waitForCaption(app, "Start by picking"))
        app.buttons["Keep New York"].tap()
        for _ in 0..<5 {
            XCTAssertTrue(caption(in: app).waitForExistence(timeout: 5))
            if caption(in: app).label.contains(text) { return }
            app.buttons["Skip step"].tap()
            sleep(1)
        }
        XCTAssertTrue(waitForCaption(app, text), "The tour never reached \(text)")
    }

    private func sheetGuide(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Tour sheet caption"]
    }

    private func waitForSheetGuide(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: sheetGuide(in: app))],
                              timeout: timeout) == .completed
    }

    private func caption(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Tour caption"]
    }

    private func waitForCaption(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: caption(in: app))],
                              timeout: timeout) == .completed
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                       timeout: timeout) == .completed
    }

    /// Offset from screen center to a point just inside the top of the peek card.
    private func cardTopOffset(_ app: XCUIApplication) -> CGFloat {
        let handle = app.buttons["Expand panel"]
        let frame = handle.exists ? handle.frame : CGRect(x: 0, y: app.frame.height - 200, width: 0, height: 0)
        return frame.maxY + 30 - app.frame.midY
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

    private func save(_ step: String, _ suffix: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(step)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
