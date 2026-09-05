import XCTest

/// End-to-end check for the share button. It lives in the profile's scroll hierarchy beside a
/// long locality name, while the panel's invisible 64pt grab strip owns nearby tap + drag input.
/// The only way to protect both layout and interaction is to exercise the running app.
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
                               "-defaultState", "DMV", "-disableLocation",
                               "-testUnitID", "51510-:-000308"]
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
        attach("collapsed-panel-long-locality")

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
        let locality = app.staticTexts["Profile locality"]
        XCTAssertTrue(locality.exists, "profile locality is missing from the expanded hero")
        let shareFrame = share.frame
        XCTAssertGreaterThanOrEqual(shareFrame.width, 44, "share target is narrower than 44pt")
        XCTAssertGreaterThanOrEqual(shareFrame.height, 44, "share target is shorter than 44pt")
        XCTAssertGreaterThanOrEqual(shareFrame.minY, collapse.frame.maxY,
                                    "share button protrudes above the profile content")
        XCTAssertLessThanOrEqual(shareFrame.maxX, app.windows.firstMatch.frame.maxX,
                                 "share button protrudes beyond the panel")
        XCTAssertFalse(shareFrame.intersects(locality.frame),
                       "long locality text sits under the share button")

        let initialShareY = shareFrame.minY
        let initialLocalityY = locality.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        let shareMovement = share.frame.minY - initialShareY
        let localityMovement = locality.frame.minY - initialLocalityY
        XCTAssertLessThan(shareMovement, -1, "share button did not move with the profile scroll")
        XCTAssertEqual(shareMovement, localityMovement, accuracy: 2,
                       "share button detached from the locality while scrolling")

        app.swipeUp()
        XCTAssertFalse(share.isHittable, "share button stayed pinned while its hero scrolled offscreen")
        XCTAssertFalse(locality.isHittable, "locality stayed pinned while its share button scrolled offscreen")

        for _ in 0..<3 where !share.isHittable { app.swipeDown() }
        XCTAssertTrue(share.isHittable, "share button did not return with the hero after scrolling back")

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

    func testTopCodedIncomeAffordanceOpensTiedPrecinctProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "NY", "-disableLocation"]
        app.launch()

        let byNumbers = app.buttons["By the numbers"]
        XCTAssertTrue(byNumbers.waitForExistence(timeout: 20), "By the numbers button missing")
        byNumbers.tap()

        let highestIncome = app.buttons["Highest income leaderboard"]
        for _ in 0..<5 where !highestIncome.exists { app.swipeUp() }
        XCTAssertTrue(highestIncome.waitForExistence(timeout: 10),
                      "highest-income tie affordance missing")
        XCTAssertTrue(highestIncome.label.contains("166 precincts tied"),
                      "highest-income affordance does not expose the true tie count")
        highestIncome.tap()

        XCTAssertTrue(app.navigationBars["Highest income"].waitForExistence(timeout: 10),
                      "income leaderboard did not open")
        XCTAssertTrue(app.staticTexts["166 precincts tie at $250k+"].waitForExistence(timeout: 10),
                      "complete tie-group header missing")

        let precinct = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'Income tied precinct '")
        ).firstMatch
        XCTAssertTrue(precinct.waitForExistence(timeout: 10), "no tied precinct row is tappable")
        precinct.tap()

        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'"))
            .firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15), "tied precinct did not open its profile")
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

    /// The visible coverage capsule follows its label inside a stable, centered Menu host. The
    /// stable host prevents a long label from being clipped to a previous short label's rectangle
    /// while the menu dismisses.
    func testCoverageAreaSwitchKeepsSelectorFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "DMV", "-disableLocation"]
        app.launch()

        let switcher = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
        ).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "coverage area selector missing")
        let windowMidX = app.windows.firstMatch.frame.midX
        let byNumbers = app.buttons["By the numbers"]
        let settings = app.buttons["Settings"]
        XCTAssertTrue(byNumbers.exists, "By the Numbers control missing")
        XCTAssertTrue(settings.exists, "Settings control missing")

        func recordSelector(named name: String) {
            let fullLabel = "Switch coverage area, currently \(name)"
            let selectedSwitcher = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", fullLabel)
            ).firstMatch
            XCTAssertTrue(selectedSwitcher.waitForExistence(timeout: 5),
                          "coverage area selector never showed the full '\(name)' label")
            XCTAssertEqual(selectedSwitcher.label, fullLabel,
                           "coverage area selector truncated '\(name)'")
            XCTAssertEqual(selectedSwitcher.frame.height, 44, accuracy: 1,
                           "selector tap height changed for '\(name)'")
            XCTAssertEqual(selectedSwitcher.frame.width, 168, accuracy: 1,
                           "stable selector host changed width for '\(name)'")
            XCTAssertEqual(selectedSwitcher.frame.midX, windowMidX, accuracy: 1,
                           "selector stopped being centered for '\(name)'")
            XCTAssertFalse(selectedSwitcher.frame.intersects(byNumbers.frame),
                           "selector host overlaps the By the Numbers control for '\(name)'")
            XCTAssertFalse(selectedSwitcher.frame.intersects(settings.frame),
                           "selector host overlaps the Settings control for '\(name)'")
            XCTAssertTrue(byNumbers.isHittable,
                          "By the Numbers control is not hittable beside '\(name)'")
            XCTAssertTrue(settings.isHittable,
                          "Settings control is not hittable beside '\(name)'")
        }

        func attachSettledSelector(named name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "coverage-selector-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        recordSelector(named: "DMV (DC, MD, VA)")
        attachSettledSelector(named: "dmv")

        switcher.tap()
        let colorado = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Colorado'")
        ).firstMatch
        XCTAssertTrue(colorado.waitForExistence(timeout: 10), "Colorado menu option missing")
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Oregon'")
        ).firstMatch.exists, "Oregon menu option missing")
        attach("coverage-picker")
        colorado.tap()
        recordSelector(named: "Colorado")

        for name in ["California", "Massachusetts", "New York", "Oregon", "Texas",
                     "DMV (DC, MD, VA)", "California"] {
            switcher.tap()
            let option = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", name)
            ).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10), "menu option '\(name)' missing")
            option.tap()
            XCTAssertTrue(switcher.waitForExistence(timeout: 5), "coverage area selector disappeared after '\(name)'")
            recordSelector(named: name)
            if name == "Texas" || name == "DMV (DC, MD, VA)" {
                attachSettledSelector(named: name == "Texas" ? "texas" : "dmv-return")
            }
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
