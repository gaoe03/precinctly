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
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO"]
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
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-defaultState", "CA"]
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

    /// Requested: compare a precinct to the places around it, not just to the whole state.
    /// The thing worth protecting is that the "vs X" caption always names the area actually
    /// used, so switching the menu has to move the labels with it.
    func testComparisonAreaSwitchesTheDeltaLabels() {
        let app = XCUIApplication()
        // Deliberately NOT seeding "-comparisonArea": a launch argument lands in NSArgumentDomain,
        // which outranks anything the app writes to UserDefaults, so the preference would be
        // frozen at the seeded value and the feature would look broken. The test drives the menu
        // in both directions instead, which is also the more honest exercise.
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO"]
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
