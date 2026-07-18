import XCTest

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
}
