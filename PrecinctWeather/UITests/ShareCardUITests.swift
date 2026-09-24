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
        // Frames arrive in floating point. A 44pt target can read 43.999999999999986.
        XCTAssertGreaterThanOrEqual(shareFrame.width, 44 - 0.01, "share target is narrower than 44pt")
        XCTAssertGreaterThanOrEqual(shareFrame.height, 44 - 0.01, "share target is shorter than 44pt")
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

    /// Regression guard for link text collapsing one word per line. The old "See all" chip was
    /// the only flexible thing in a fact row, so a long place name squeezed it until it wrapped
    /// character by character. The "See precincts" links replaced it, and each chart's extreme
    /// place names now share a row in two equal columns. CA is the reproduction: its place
    /// strings are the longest.
    func testSeePrecinctsLinksAndExtremeNamesNeverSqueeze() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "CA", "-disableLocation"]
        app.launch()

        let byNumbers = app.buttons["By the numbers"]
        XCTAssertTrue(byNumbers.waitForExistence(timeout: 20), "By the numbers button missing")
        byNumbers.tap()

        let links = app.buttons.matching(NSPredicate(format: "label == 'See precincts'"))
        XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 15), "no See precincts links on the page")
        let extremes = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'Highest, ' OR label BEGINSWITH 'Lowest, ' OR label BEGINSWITH 'Most ' "
            + "OR label BEGINSWITH 'Least ' OR label BEGINSWITH 'Biggest swing ' OR label BEGINSWITH 'Smallest swing '"))
        let windowWidth = app.windows.firstMatch.frame.width

        // A link on one line measures about 20pt. A wrapped one measured 26pt, so 24 separates
        // them with room to spare. A place name may wrap to two lines of the column's own title
        // size, and its column keeps close to half the row.
        var worstLink: (label: String, height: CGFloat) = ("none", 0)
        var worstName: (label: String, lines: CGFloat) = ("none", 0)
        var narrowest: (label: String, width: CGFloat) = ("none", .greatestFiniteMagnitude)
        var namesChecked = 0
        for _ in 0..<14 {
            for i in 0..<links.count {
                let link = links.element(boundBy: i)
                guard link.exists, link.frame.height > 0 else { continue }
                if link.frame.height > worstLink.height { worstLink = (link.label, link.frame.height) }
            }
            for i in 0..<extremes.count {
                let extreme = extremes.element(boundBy: i)
                guard extreme.exists, extreme.frame.height > 0 else { continue }
                let texts = extreme.staticTexts.allElementsBoundByIndex
                guard let title = texts.first, let name = texts.last, texts.count >= 2,
                      title.frame.height > 0 else { continue }
                namesChecked += 1
                let lines = name.frame.height / title.frame.height
                if lines > worstName.lines { worstName = (name.label, lines) }
                if extreme.frame.width < narrowest.width { narrowest = (extreme.label, extreme.frame.width) }
            }
            app.swipeUp()
        }
        attach("by-the-numbers")
        XCTAssertLessThan(worstLink.height, 24,
                          "link '\(worstLink.label)' is \(worstLink.height)pt tall, so it wrapped onto multiple lines")
        XCTAssertGreaterThan(namesChecked, 0, "no extreme place names on the page")
        XCTAssertLessThanOrEqual(worstName.lines, 2.2,
                                 "place '\(worstName.label)' spans \(worstName.lines) lines, so its column was squeezed")
        XCTAssertGreaterThan(narrowest.width, windowWidth * 0.4,
                             "extreme '\(narrowest.label)' is only \(narrowest.width)pt wide")
    }

    func testTopCodedIncomeAffordanceOpensTiedPrecinctProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "NY", "-disableLocation"]
        app.launch()

        let byNumbers = app.buttons["By the numbers"]
        XCTAssertTrue(byNumbers.waitForExistence(timeout: 20), "By the numbers button missing")
        byNumbers.tap()

        // The income chart's Highest end names the tie instead of one arbitrary precinct.
        let highestIncome = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Highest, $250k+'")
        ).firstMatch
        for _ in 0..<10 where !highestIncome.isHittable { app.swipeUp() }
        XCTAssertTrue(highestIncome.waitForExistence(timeout: 10),
                      "highest-income tie affordance missing")
        XCTAssertTrue(highestIncome.label.contains("166 precincts tied"),
                      "highest-income affordance does not expose the true tie count: \(highestIncome.label)")
        highestIncome.tap()

        XCTAssertTrue(app.staticTexts["All precincts"].waitForExistence(timeout: 10),
                      "the tie did not open the ranked list")
        assertSortsFromTheTop(app)
        let precinct = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH ', $250k+'")
        ).firstMatch
        XCTAssertTrue(precinct.waitForExistence(timeout: 10), "no tied precinct row is tappable")
        attach("income-tie-list")
        precinct.tap()

        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Political lean'"))
            .firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15), "tied precinct did not open its profile")
    }

    /// A tie at a chart's end must open the full ranking even when the reader has a precinct
    /// selected. "See precincts" opens on the reader's own bar, and the tie link once did the
    /// same, which hid every tied precinct behind an unrelated bar.
    func testTiedExtremeOpensFullRankingWithAPrecinctSelected() {
        for testCase in [(prefix: "Highest, $250k+", value: "$250k+"),
                         (prefix: "Most Democratic, D+96", value: "D+96")] {
            let app = XCUIApplication()
            // Queens 1320 sits in the $75k to 100k income bar and the Even lean bar, so neither
            // tie is in the selected precinct's own bar.
            app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                                   "-defaultState", "NY", "-disableLocation",
                                   "-testUnitID", "36081-:-36081001320"]
            app.launch()

            let hero = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Political lean'")).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 30), "no precinct was selected")
            let byNumbers = app.buttons["By the numbers"]
            XCTAssertTrue(byNumbers.waitForExistence(timeout: 10), "By the numbers button missing")
            byNumbers.tap()

            let tie = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", testCase.prefix)).firstMatch
            for _ in 0..<10 where !tie.isHittable { app.swipeUp() }
            XCTAssertTrue(tie.waitForExistence(timeout: 10), "'\(testCase.prefix)' end missing")
            XCTAssertTrue(tie.label.contains("precincts tied"), "'\(testCase.prefix)' is not a tie: \(tie.label)")
            tie.tap()

            XCTAssertTrue(app.staticTexts["All precincts"].waitForExistence(timeout: 10),
                          "the tie opened a filtered list instead of the full ranking")
            assertSortsFromTheTop(app)
            let rows = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", \(testCase.value)"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10),
                          "no row shows the tied value \(testCase.value)")
            let header = app.staticTexts["All precincts"]
            // Rows read "Precinct 1146, Queens, value", with a leading rank only when values
            // differ. The map controls stay in the tree under the cover, so match the row shape.
            let firstRow = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(\\d+, )?Precinct [^,]+, [^,]+, .+"))
                .allElementsBoundByIndex
                .filter { $0.frame.minY >= header.frame.maxY - 1 && $0.frame.height > 0 }
                .min { $0.frame.minY < $1.frame.minY }
            XCTAssertTrue(firstRow?.label.hasSuffix(", \(testCase.value)") == true,
                          "first row is not a tied precinct: \(firstRow?.label ?? "none")")
            attach("tie-with-selection-\(testCase.value)")
            app.terminate()
        }
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

    /// The coverage selector hugs its label, so its width follows the area name. Every area must
    /// still show its full name at the full tap height without running into the controls beside it.
    func testCoverageAreaSwitchKeepsSelectorFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO",
                               "-defaultState", "DMV", "-disableLocation"]
        app.launch()

        let switcher = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Switch coverage area'")
        ).firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "coverage area selector missing")
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
            // The area is the page title, and tapping it opens the county picker.
            XCTAssertTrue(app.buttons["By the Numbers, \(testCase.stateName)"].waitForExistence(timeout: 15),
                          "\(testCase.stateName) By the Numbers scope missing")
            XCTAssertTrue(app.staticTexts["Politics"].waitForExistence(timeout: 15),
                          "\(testCase.stateName) political facts missing")
            let demographics = app.staticTexts["Who lives here"]
            for _ in 0..<6 where !demographics.exists { app.swipeUp() }
            XCTAssertTrue(demographics.exists, "\(testCase.stateName) demographic facts missing")
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
            format: "label CONTAINS 'No election data. Demographics are still available.'"
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
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings did not open")
        // The About section sits below the fold, and the list only builds rows near the screen.
        let sources = app.buttons["Sources and licenses"]
        for _ in 0..<5 where !sources.isHittable { app.swipeUp() }
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
    /// The thing worth protecting is that the "vs X" chip always names the area actually used,
    /// so switching the menu has to move the chip and the numbers with it.
    func testComparisonAreaSwitchesTheDeltaLabels() {
        let app = XCUIApplication()
        // Deliberately NOT seeding "-comparisonArea": a launch argument lands in NSArgumentDomain,
        // which outranks anything the app writes to UserDefaults, so the preference would be
        // frozen at the seeded value and the feature would look broken. The test drives the menu
        // in every direction instead, which is also the more honest exercise.
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

        // Queens is a NYC borough, so this precinct should offer all three areas. Each item is the
        // full name with its kind under it.
        let queens = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queens'")).firstMatch
        let city = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New York City'")).firstMatch
        let state = app.buttons.matching(
            NSPredicate(format: "label == 'New York' OR label BEGINSWITH 'New York, '")
        ).firstMatch
        menu.tap()
        XCTAssertTrue(queens.waitForExistence(timeout: 5), "county option missing from the menu")
        XCTAssertTrue(city.exists, "NYC option missing for a borough precinct")
        XCTAssertTrue(state.exists, "state option missing")
        attach("compare-menu")
        state.tap()

        let stateDeltas = settledDeltas(app, menu: menu, area: "NY")
        attach("compare-state")

        menu.tap()
        XCTAssertTrue(queens.waitForExistence(timeout: 5), "county option missing on reopen")
        queens.tap()
        let countyDeltas = settledDeltas(app, menu: menu, area: "Queens")
        XCTAssertNotEqual(countyDeltas, stateDeltas, "the numbers should change, not just the label")
        attach("compare-county")

        menu.tap()
        XCTAssertTrue(city.waitForExistence(timeout: 5), "NYC option missing on reopen")
        city.tap()
        let cityDeltas = settledDeltas(app, menu: menu, area: "NYC")
        XCTAssertNotEqual(cityDeltas, countyDeltas, "the numbers should change, not just the label")
        attach("compare-city")
    }

    /// Waits for the chip to name `area`, then returns the income and college deltas. The chip
    /// names the area, so the deltas themselves are bare ("+$12k", "−31 pts").
    private func settledDeltas(_ app: XCUIApplication, menu: XCUIElement, area: String,
                               file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Compare against, currently \(area)"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "chip did not follow the choice: \(menu.label)", file: file, line: line)
        XCTAssertTrue(app.staticTexts["vs \(area)"].exists, "chip text does not read 'vs \(area)'",
                      file: file, line: line)
        // Let the numeric content transition finish before reading the values.
        sleep(1)
        let deltas = ["Median income", "College degree"].map { name -> String in
            let stat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(stat.exists, "\(name) stat missing", file: file, line: line)
            let delta = stat.label.components(separatedBy: ", ").last ?? ""
            XCTAssertNotNil(delta.range(of: "^[+−-]", options: .regularExpression),
                            "\(name) has no delta vs \(area): \(stat.label)", file: file, line: line)
            XCTAssertFalse(delta.contains("vs"), "\(name) delta still names the area: \(delta)",
                           file: file, line: line)
            return delta
        }
        return deltas
    }

    /// The ranking opened from a highest extreme sorts from the top ("Highest first", or
    /// "Most Democratic first" on the lean chart), never from the bottom.
    private func assertSortsFromTheTop(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort, currently'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the list has no sort chip", file: file, line: line)
        XCTAssertFalse(["Lowest", "Most Republican", "Toward R"].contains { chip.label.contains($0) },
                       "the ranking sorts from the bottom: \(chip.label)", file: file, line: line)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIApplication().screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
