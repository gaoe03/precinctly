import XCTest

/// End-to-end check for the share button. It exists because the button is layered over the
/// panel's invisible 64pt grab strip (which owns tap + drag): the only way to know its taps
/// aren't swallowed is to actually tap it in a running app.
///
/// Requires the simulator to have a location set inside coverage and location access granted:
///   xcrun simctl privacy <sim> grant location com.gaoe.PrecinctWeather
///   xcrun simctl location <sim> set 40.7498,-73.8648
final class ShareCardUITests: XCTestCase {

    func testShareButtonOpensShareSheet() {
        let app = XCUIApplication()
        // NSArgumentDomain beats the persisted value, so @AppStorage reads these without the
        // app knowing it's under test and without polluting the sim's defaults.
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "NY", "-disableLocation",
                               "-testUnitID", "36081-:-36081001320"]
        // Lets one run check a different appearance without editing the test:
        //   TEST_RUNNER_APPEARANCE=dark xcodebuild test ...
        if let appearance = ProcessInfo.processInfo.environment["APPEARANCE"] {
            app.launchArguments += ["-appearanceMode", appearance]
        }
        app.launch()

        // The hero's combined accessibility label is the app's own signal that a precinct
        // resolved. Waiting on it (rather than a fixed sleep) is what keeps this from flaking
        // on however long the GPS fix takes.
        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "no precinct was selected, so there is nothing to share")

        // Expand via the handle, not by tapping the card body: at accessibility text sizes the
        // tap-to-expand catcher deliberately steps aside so the taller hero can scroll, and the
        // handle is the one affordance that expands at every size.
        let handle = app.buttons["Expand panel"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "panel handle missing")
        handle.tap()

        let share = app.buttons["Share this precinct"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "share button never appeared on the expanded panel")
        XCTAssertTrue(share.isHittable, "share button exists but is not hittable (grab strip is swallowing it)")

        let collapse = app.buttons["Collapse panel"]
        XCTAssertTrue(collapse.exists, "expanded panel handle missing")
        let shareFrame = share.frame
        XCTAssertEqual(shareFrame.width, 34, accuracy: 1, "share circle width changed")
        XCTAssertEqual(shareFrame.height, 34, accuracy: 1, "share circle height changed")
        XCTAssertGreaterThanOrEqual(shareFrame.minY - collapse.frame.minY, 6,
                                    "share button protrudes above the white panel")
        XCTAssertEqual(app.windows.firstMatch.frame.maxX - shareFrame.maxX, 12, accuracy: 2,
                       "share button trailing inset changed")
        app.swipeUp()
        XCTAssertEqual(share.frame.minY, shareFrame.minY, accuracy: 1,
                       "share button moved out of the panel while its content scrolled")

        attach("expanded-panel")

        share.tap()

        // Our own preview screen comes first. Waiting on the card image (not just the buttons)
        // is what proves the async render finished, map hero and all.
        let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Share card for'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25), "the share preview never finished rendering the card")

        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.exists, "preview is missing its Save action")
        XCTAssertTrue(app.buttons["Copy"].exists, "preview is missing its Copy action")

        attach("share-preview")

        // Copy needs no permission dialog, so it is the one action a test can drive end to end.
        // The confirmation lands on the button itself, so the button is what changes.
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 4), "Copy gave no confirmation")
        XCTAssertFalse(app.buttons["Copy"].exists, "the button should report the result, not sit unchanged")
        attach("copy-confirmed")

        // Only then does Apple's sheet appear.
        app.buttons["Share"].firstMatch.tap()
        let sheetAppeared = app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
            || app.buttons["Close"].waitForExistence(timeout: 3)
        XCTAssertTrue(sheetAppeared, "tapping Share did not present the activity sheet")

        attach("share-sheet")
    }

    /// Regression guard for the "See all" chip collapsing to "Se / e / all". The chip was the
    /// only flexible thing in a fact row, so a long place name squeezed it until it wrapped
    /// character by character. CA is the reproduction: its place strings are the longest.
    func testSeeAllChipsNeverWrap() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "CA", "-disableLocation"]
        app.launch()

        let byNumbers = app.buttons["By the numbers"]
        XCTAssertTrue(byNumbers.waitForExistence(timeout: 20), "By the numbers button missing")
        byNumbers.tap()

        let chips = app.staticTexts.matching(NSPredicate(format: "label == 'See all' OR label ENDSWITH 'precincts'"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 15), "no See all chips on the page")

        // A chip on one line measures about 20pt. A wrapped one measured 26pt, which is the
        // failure the friend hit, so 24 separates them with room to spare.
        var worst: (label: String, height: CGFloat) = ("none", 0)
        for _ in 0..<6 {
            for i in 0..<chips.count {
                let chip = chips.element(boundBy: i)
                guard chip.exists, chip.frame.height > 0 else { continue }
                if chip.frame.height > worst.height { worst = (chip.label, chip.frame.height) }
            }
            app.swipeUp()
        }
        attach("by-the-numbers")
        XCTAssertLessThan(worst.height, 24,
                          "chip '\(worst.label)' is \(worst.height)pt tall, so it wrapped onto multiple lines")
    }

    /// Apple Maps puts Midway City's representative point in a sub-meter seam between public
    /// precinct polygons. Search should still open an Orange County precinct instead of claiming
    /// that a California place is outside coverage.
    func testMidwayCitySearchResolvesCaliforniaPrecinct() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "CA", "-disableLocation"]
        app.launch()

        let searchButton = app.buttons["Search addresses and places"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "search button missing")
        searchButton.tap()

        let field = app.searchFields["Address or place"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field missing")
        field.tap()
        field.typeText("Midway City")

        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Midway City'"))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Midway City, CA result missing")
        result.tap()

        XCTAssertFalse(app.staticTexts["Outside covered areas"].waitForExistence(timeout: 2),
                       "covered California result was rejected")
        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15), "search did not load a precinct profile")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Orange County, CA'")
        ).firstMatch.exists, "search did not land in Orange County")
        attach("midway-search")
    }

    /// Switching coverage areas used to animate the pill before the destination profile and
    /// county tint had settled. Repeated switches should keep one stable control frame and never
    /// expose a stale destination while the new map loads.
    func testCoverageAreaSwitchKeepsSelectorFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "DMV", "-disableLocation"]
        app.launch()

        let switcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
        ).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "coverage area selector missing")
        let initialWidth = switcher.frame.width

        switcher.tap()
        XCTAssertTrue(app.buttons["Colorado"].waitForExistence(timeout: 10), "Colorado menu option missing")
        XCTAssertTrue(app.buttons["Oregon"].exists, "Oregon menu option missing")
        attach("coverage-picker")
        app.buttons["Colorado"].tap()

        for name in ["California", "Oregon", "Texas", "DMV (DC, MD, VA)", "California"] {
            switcher.tap()
            let option = app.buttons[name].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10), "menu option '\(name)' missing")
            option.tap()
            XCTAssertTrue(switcher.waitForExistence(timeout: 5), "coverage area selector disappeared after '\(name)'")
            XCTAssertEqual(switcher.frame.width, initialWidth, accuracy: 1.0,
                           "selector width changed after switching to '\(name)'")
        }
    }

    func testOregonAndColoradoPopularPlacesOpenProfilesAndByNumbers() {
        for testCase in [
            (state: "OR", stateName: "Oregon", place: "Portland"),
            (state: "CO", stateName: "Colorado", place: "Denver"),
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                                   "-defaultState", "NY", "-disableLocation"]
            app.launch()

            let switcher = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
            ).firstMatch
            XCTAssertTrue(switcher.waitForExistence(timeout: 15),
                          "coverage area selector missing for \(testCase.state)")
            switcher.tap()
            let destination = app.buttons[testCase.stateName].firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 10),
                          "\(testCase.stateName) coverage option missing")
            destination.tap()

            let search = app.buttons["Search addresses and places"]
            XCTAssertTrue(search.waitForExistence(timeout: 15), "search missing for \(testCase.state)")
            search.tap()
            let place = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", testCase.place)
            ).firstMatch
            XCTAssertTrue(place.waitForExistence(timeout: 10), "\(testCase.place) popular place missing")
            place.tap()

            let hero = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 15), "\(testCase.place) profile missing")
            XCTAssertTrue(app.buttons.matching(
                NSPredicate(format: "label == %@", "Switch coverage area, currently \(testCase.stateName)")
            ).firstMatch.exists, "coverage did not switch to \(testCase.stateName)")
            attach("\(testCase.state.lowercased())-profile")

            app.buttons["By the numbers"].tap()
            XCTAssertTrue(app.staticTexts["All of \(testCase.stateName)"].waitForExistence(timeout: 15),
                          "\(testCase.stateName) By the Numbers scope missing")
            XCTAssertTrue(app.staticTexts["Politics"].exists, "\(testCase.stateName) political facts missing")
            XCTAssertTrue(app.staticTexts["Race & demographics"].exists,
                          "\(testCase.stateName) demographic facts missing")
            attach("\(testCase.state.lowercased())-by-the-numbers")
            app.terminate()
        }
    }

    func testElectionNullProfileKeepsDemographicsAndSharePreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "OR", "-disableLocation",
                               "-testUnitID", "41005-:-X000"]
        app.launch()

        let noElection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'No election data'")).firstMatch
        XCTAssertTrue(noElection.waitForExistence(timeout: 20), "null-election profile was not selected")
        XCTAssertFalse(noElection.label.contains("Political lean"), "null profile claims a political lean")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label MATCHES '[DR]\\+[0-9]+'"))
            .firstMatch.exists, "null profile displays a partisan margin")

        app.buttons["Expand panel"].tap()
        XCTAssertTrue(app.staticTexts["Who lives here"].waitForExistence(timeout: 10),
                      "null profile lost demographic sections")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Election data is unavailable for this precinct'")
        ).firstMatch.waitForExistence(timeout: 5), "null profile footer is not explicit")
        attach("or-null-profile")

        app.buttons["Share this precinct"].tap()
        let card = app.images.matching(NSPredicate(
            format: "label CONTAINS 'No election data. The card uses neutral election text and omits the vote bar.'"
        ))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25), "null profile share preview did not render")
        XCTAssertFalse(card.label.contains("Political lean"), "null share card advertises a political lean")
        attach("or-null-share-preview")
    }

    func testSourcesDiscloseOregonAndColoradoElectionYears() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "OR", "-disableLocation"]
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "settings button missing")
        settings.tap()
        let sources = app.buttons["Sources and licenses"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10), "sources link missing")
        sources.tap()

        XCTAssertTrue(app.staticTexts["Privately supplied Oregon and Colorado dataset"]
            .waitForExistence(timeout: 10), "Oregon and Colorado source disclosure missing")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '1,296 precincts use 2020'")
        ).firstMatch.exists, "Oregon election-year disclosure missing")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '3,138 precincts use 2024'")
        ).firstMatch.exists, "Colorado election-year disclosure missing")
        attach("or-co-sources")
    }

    /// DMV is an aggregate navigation area, not a dead-end screen. A map tap at the DMV center
    /// must still resolve a precinct and show its profile.
    func testDMVMapTapResolvesPrecinct() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "DMV", "-disableLocation"]
        app.launch()

        let switcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
        ).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "coverage area selector missing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()

        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'"))
            .firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "DMV map tap did not resolve a precinct")

        switcher.tap()
        let california = app.buttons["California"].firstMatch
        XCTAssertTrue(california.waitForExistence(timeout: 10), "state menu did not open after a DMV selection")
        california.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label == 'Switch coverage area, currently California'")
        ).firstMatch.waitForExistence(timeout: 5), "could not leave DMV after selecting a precinct")
    }

    /// The first tap after switching into DMV must work too. This catches a camera or gesture
    /// state left behind by the previous state's selection flight.
    func testSwitchIntoDMVThenTapMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "CA", "-disableLocation"]
        app.launch()

        let switcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
        ).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "coverage area selector missing")
        switcher.tap()
        let dmv = app.buttons["DMV (DC, MD, VA)"].firstMatch
        XCTAssertTrue(dmv.waitForExistence(timeout: 10), "DMV menu option missing")
        dmv.tap()

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'"))
            .firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "first DMV map tap after switching did not resolve")
    }

    /// Requested: compare a precinct to the places around it, not just to the whole state.
    /// The thing worth protecting is that the "vs X" caption always names the area actually
    /// used, so switching the menu has to move the labels with it.
    func testComparisonAreaSwitchesTheDeltaLabels() {
        let app = XCUIApplication()
        // Deliberately NOT seeding "-comparisonArea": a launch argument lands in NSArgumentDomain,
        // which outranks anything the app writes to UserDefaults, so the preference would be
        // frozen at the seeded value and the feature would look broken. The test drives the menu
        // in both directions instead, which is also the more honest exercise.
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "NY", "-disableLocation",
                               "-testUnitID", "36081-:-36081001320"]
        app.launch()

        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "no precinct was selected")
        app.buttons["Expand panel"].tap()

        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Compare against'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no comparison menu on the money section")

        // Queens is a NYC borough, so this precinct should offer all three areas.
        menu.tap()
        XCTAssertTrue(app.buttons["Queens"].waitForExistence(timeout: 5), "county option missing from the menu")
        XCTAssertTrue(app.buttons["NYC"].exists, "NYC option missing for a borough precinct")
        XCTAssertTrue(app.buttons["NY"].exists, "state option missing")
        app.buttons["NY"].tap()

        XCTAssertTrue(app.staticTexts["vs NY"].waitForExistence(timeout: 5), "menu did not settle on the state")
        XCTAssertTrue(deltaLabels(app).allSatisfy { $0.hasSuffix("vs NY") },
                      "state deltas should read 'vs NY', got \(deltaLabels(app))")
        let stateDeltas = deltaLabels(app)
        attach("compare-state")

        menu.tap()
        app.buttons["Queens"].tap()

        XCTAssertTrue(app.staticTexts["vs Queens"].waitForExistence(timeout: 5), "menu label did not follow the choice")
        let after = deltaLabels(app)
        XCTAssertFalse(after.isEmpty, "no deltas rendered after switching")
        XCTAssertTrue(after.allSatisfy { $0.hasSuffix("vs Queens") },
                      "deltas should name the area actually used, got \(after)")
        XCTAssertNotEqual(after, stateDeltas, "the numbers should change, not just the label")
        attach("compare-county")
    }

    /// The "+$12k vs TX" style captions under the money and education stats.
    private func deltaLabels(_ app: XCUIApplication) -> [String] {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[+−-].* vs .*'"))
            .allElementsBoundByIndex.map(\.label)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIApplication().screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
