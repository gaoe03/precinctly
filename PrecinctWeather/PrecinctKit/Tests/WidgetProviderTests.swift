import CoreLocation
import XCTest

final class WidgetProviderTests: XCTestCase {
    func testProviderRejectsStaleAndInaccurateFixesInsteadOfSelectingTheirPrecinct() async {
        for (accuracy, age) in [(10.0, 3_600.0), (500.0, 0.0), (-1.0, 0.0)] {
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 40.758, longitude: -73.985),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                timestamp: Date().addingTimeInterval(-age)
            )
            let entry = await resolve(location)
            XCTAssertNil(entry.profile, "An unusable location must not produce a confident precinct")
            XCTAssertFalse(entry.outOfCoverage, "An unusable fix does not prove the reader is outside coverage")
        }
    }

    func testProviderResolvesFreshLocationAndKeepsOutsideCoverageEmpty() async {
        let covered = await resolve(CLLocation(latitude: 40.758, longitude: -73.985))
        XCTAssertEqual(covered.profile?.state, "NY")
        XCTAssertFalse(covered.trend.isEmpty)
        XCTAssertNotNil(covered.baseline)
        XCTAssertFalse(covered.outOfCoverage)

        let outside = await resolve(CLLocation(latitude: 39.9496, longitude: -75.1503))
        XCTAssertNil(outside.profile)
        XCTAssertTrue(outside.outOfCoverage)
        XCTAssertTrue(outside.trend.isEmpty)
    }

    private func resolve(_ location: CLLocation?) async -> PrecinctEntry {
        await withCheckedContinuation { continuation in
            PrecinctProvider(locationProvider: { location }).resolve { entry in
                continuation.resume(returning: entry)
            }
        }
    }
}
