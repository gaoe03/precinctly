import XCTest
import UIKit

final class VisualFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLargestTextProfileAndShareKeepLabelsReadable() throws {
        let app = launch(largestText: true)
        app.buttons["Expand panel"].tap()
        let share = app.buttons["Share this precinct"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        attach("large-text-profile", app)
        try auditClipping(app)

        share.tap()
        let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Share card for'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(card.label.contains("Political lean R+45"))
        for label in ["Share", "Save to Photos", "Copy"] {
            XCTAssertTrue(app.buttons[label].isHittable, "\(label) is not reachable at the largest text size")
        }
        attach("large-text-share", app)
        try auditClipping(app)
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 4))
    }

    func testLargestTextProfileCanReachAllSectionsAndFooter() throws {
        let app = launch(largestText: true)
        app.buttons["Expand panel"].tap()
        for label in ["Largest group: White", "Money and education", "People and housing",
                      "2020 presidential vote. Demographics use the 2020 Census and ACS."] {
            let element = app.staticTexts[label]
            for _ in 0..<10 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, "\(label) could not be reached")
            attach("large-text-\(label.prefix(18))", app)
            try auditClipping(app)
        }
        try auditClipping(app)
    }

    func testSettingsAndRankingsInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            attach("settings-\(appearance)", app)
            try auditClipping(app)
            app.buttons["Done"].tap()
            app.buttons["By the numbers"].tap()
            XCTAssertTrue(app.buttons["About this data"].waitForExistence(timeout: 10))
            attach("rankings-\(appearance)", app)
            app.buttons["About this data"].tap()
            XCTAssertTrue(app.navigationBars["About This Data"].waitForExistence(timeout: 5))
            attach("data-notes-\(appearance)", app)
            try auditClipping(app)
            app.terminate()
        }
    }

    func testLargestTextRankingsKeepBothValuesOnscreen() throws {
        let app = launch(largestText: true)
        app.buttons["By the numbers"].tap()
        let scope = app.buttons["All of Oregon"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10))
        attach("large-text-rankings-overview", app)
        try auditClipping(app)
        let screen = app.windows.firstMatch.frame
        for id in ["dem", "rep"] {
            let value = app.staticTexts["Range value \(id)"]
            for _ in 0..<20 {
                if value.exists && value.frame.minY > screen.minY + 120
                    && value.frame.maxY < screen.maxY - 40 { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            XCTAssertTrue(value.exists, app.debugDescription)
            XCTAssertGreaterThan(value.frame.width, 0)
            XCTAssertGreaterThan(value.frame.minY, screen.minY + 120)
            XCTAssertLessThan(value.frame.maxY, screen.maxY - 40)
            XCTAssertGreaterThanOrEqual(value.frame.minX, screen.minX)
            XCTAssertLessThanOrEqual(value.frame.maxX, screen.maxX)
            attach("large-text-rankings-value-\(id)", app)
            // The whole-screen audit also flags adjacent list rows cut by the viewport.
            // Check the actual value's complete frame at each scroll position instead.
            XCTAssertEqual(value.label, id == "dem" ? "D+92" : "R+94")
        }
        app.buttons["Range endpoint rep"].tap()
        XCTAssertTrue(app.buttons["Expand panel"].waitForExistence(timeout: 10))
    }

    func testGreeneMapAndShareRenderTheHoleFixture() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "NY", "-testUnitID", "36039-:-36039000039",
                               "-appearanceMode", "light", "-colorNeighbors", "NO",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["Expand panel"].waitForExistence(timeout: 15))
        attach("greene-map-after", app)
        app.buttons["Expand panel"].tap()
        let share = app.buttons["Share this precinct"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        attach("greene-expanded", app)
        share.tap()
        let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Share card for'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        attach("greene-share-after", app)
    }

    func testShareCardMatchesLightAndDarkAppearance() throws {
        for appearance in ["dark", "light"] {
            let app = launch(appearance: appearance)
            app.buttons["Expand panel"].tap()
            let share = app.buttons["Share this precinct"]
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            share.tap()
            let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Share card for'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 30))
            attach("share-appearance-\(appearance)", app)
            try assertStock(card, isDark: appearance == "dark")
            app.terminate()
        }
    }

    func testShareCardUpdatesWhenAutomaticAppearanceChanges() throws {
        let original = XCUIDevice.shared.appearance
        defer { setSystemAppearance(dark: original == .dark) }
        setSystemAppearance(dark: false)
        let app = launch(appearance: "auto")
        app.buttons["Expand panel"].tap()
        let share = app.buttons["Share this precinct"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Share card for'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        try assertStock(card, isDark: false)
        setSystemAppearance(dark: true)
        app.activate()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                              object: app.buttons["Copy"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        attach("share-auto-changed", app)
        try assertStock(card, isDark: true)
        attach("share-auto-dark", app)
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        setSystemAppearance(dark: false)
        app.activate()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        try assertStock(card, isDark: false)
        attach("share-auto-return-light", app)
        app.terminate()
        setSystemAppearance(dark: true)
        app.launch()
        XCTAssertTrue(app.buttons["Expand panel"].waitForExistence(timeout: 15))
        app.buttons["Expand panel"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        try assertStock(card, isDark: true)
        attach("share-auto-cold-dark", app)
    }

    private func setSystemAppearance(dark: Bool) {
        guard let endpoint = ProcessInfo.processInfo.environment["APPEARANCE_TEST_URL"],
              let url = URL(string: endpoint + (dark ? "/dark" : "/light")) else {
            XCTFail("Run appearance tests through scripts/test.py")
            return
        }
        let done = expectation(description: "System appearance applied to target simulator")
        URLSession.shared.dataTask(with: url) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func assertStock(_ card: XCUIElement, isDark: Bool,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let screenshot = try XCTUnwrap(card.screenshot().image.cgImage)
        let patch = try XCTUnwrap(screenshot.cropping(to: CGRect(
            x: CGFloat(screenshot.width) * 0.5, y: CGFloat(screenshot.height) * 0.985,
            width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let brightness = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 765
        if isDark { XCTAssertLessThan(brightness, 0.25, "Export forced light stock", file: file, line: line) }
        else { XCTAssertGreaterThan(brightness, 0.85, "Export forced dark stock", file: file, line: line) }
    }

    private func launch(largestText: Bool = false, appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hasOnboarded", "YES", "-hapticsEnabled", "NO", "-disableLocation",
                               "-defaultState", "OR", "-testUnitID", "41001-:-0001",
                               "-appearanceMode", appearance,
                               "-UIPreferredContentSizeCategoryName",
                               largestText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["Expand panel"].waitForExistence(timeout: 15))
        return app
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func auditClipping(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: .textClipped) { issue in
            let detail = XCTAttachment(string: "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied")")
            detail.name = "clipping-issue"
            detail.lifetime = .keepAlways
            self.add(detail)
            return false
        }
    }
}
