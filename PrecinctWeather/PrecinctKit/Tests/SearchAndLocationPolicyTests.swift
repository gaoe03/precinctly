import XCTest
import CoreLocation

final class SearchAndLocationPolicyTests: XCTestCase {
    func testOnlyLatestCompletedSearchCanBeConsumed() throws {
        var gate = SearchResolutionGate()
        let older = gate.begin()
        let newer = gate.begin()

        XCTAssertNil(gate.complete(older))
        XCTAssertTrue(gate.isCurrent(newer))
        let latestReceipt = try XCTUnwrap(gate.complete(newer))
        XCTAssertTrue(gate.consume(latestReceipt))
        XCTAssertNil(gate.activeToken)

        let canceled = gate.begin()
        let canceledReceipt = try XCTUnwrap(gate.complete(canceled))
        gate.cancel()
        XCTAssertFalse(gate.isCurrent(canceled))
        XCTAssertFalse(gate.consume(canceledReceipt))
    }

    func testWidgetLocationAccuracyAndAgeBoundaries() {
        XCTAssertTrue(WidgetLocationPolicy.isUsable(horizontalAccuracy: 0, age: 0))
        XCTAssertTrue(WidgetLocationPolicy.isUsable(horizontalAccuracy: 100, age: 60))
        XCTAssertTrue(WidgetLocationPolicy.isUsable(horizontalAccuracy: 100, age: -60))
        XCTAssertFalse(WidgetLocationPolicy.isUsable(horizontalAccuracy: -1, age: 0))
        XCTAssertFalse(WidgetLocationPolicy.isUsable(horizontalAccuracy: 100.01, age: 0))
        XCTAssertFalse(WidgetLocationPolicy.isUsable(horizontalAccuracy: 100, age: 60.01))
        XCTAssertFalse(WidgetLocationPolicy.isUsable(horizontalAccuracy: .nan, age: 0))
        XCTAssertFalse(WidgetLocationPolicy.isUsable(horizontalAccuracy: 10, age: .infinity))
    }

    func testCompletedSearchCannotApplyAfterANewerRequestStarts() throws {
        var gate = SearchResolutionGate()
        let oldToken = gate.begin()
        let oldReceipt = try XCTUnwrap(gate.complete(oldToken))
        let newToken = gate.begin()

        XCTAssertFalse(gate.consume(oldReceipt))
        XCTAssertFalse(gate.finish(oldToken))
        XCTAssertTrue(gate.isCurrent(newToken))
        let newReceipt = try XCTUnwrap(gate.complete(newToken))
        XCTAssertTrue(gate.consume(newReceipt))
        XCTAssertFalse(gate.consume(newReceipt), "A result must only change the selection once")
        XCTAssertNil(gate.activeToken)
    }

    func testWidgetRejectsOldOrInaccurateLocationsBeforePrecinctLookup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func location(accuracy: Double, age: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40.758, longitude: -73.985),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertNil(WidgetLocationPolicy.usableLocation(nil, now: now))
        XCTAssertNil(WidgetLocationPolicy.usableLocation(location(accuracy: 5, age: 3_600), now: now))
        XCTAssertNil(WidgetLocationPolicy.usableLocation(location(accuracy: 500, age: 0), now: now))
        XCTAssertNil(WidgetLocationPolicy.usableLocation(location(accuracy: -1, age: 0), now: now))
        let fresh = location(accuracy: 10, age: 5)
        XCTAssertEqual(WidgetLocationPolicy.usableLocation(fresh, now: now), fresh)
    }
}
