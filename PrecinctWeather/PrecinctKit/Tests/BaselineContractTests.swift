import Foundation
import XCTest
@testable import PrecinctKit

/// Contract tests for the baseline rows `apply_area_baselines.py` writes into the bundled DB.
/// The script has its own validation gate, but that only runs when someone runs the script; these
/// run on every build and catch a DB that shipped without the county and metro rows, which would
/// silently collapse the comparison picker back to statewide.
final class BaselineContractTests: XCTestCase {
    private let db = PrecinctDB.shared

    private func profile(state: String, borough: String) -> PrecinctProfile? {
        // A real precinct, so the scope keys are built from data the DB actually contains.
        db.lookup(lon: coords[borough]!.lon, lat: coords[borough]!.lat)?.profile
    }
    private let coords: [String: (lat: Double, lon: Double)] = [
        "Brooklyn": (40.6782, -73.9442),
        "Clackamas": (45.40891980198354, -122.70067593180136),
        "Denver": (39.7392, -104.9903),
        "Manhattan": (40.7580, -73.9850),
        "Harris": (29.7604, -95.3698),
        "San Francisco": (37.7765, -122.4222),
    ]

    func testEveryCoveredStateStillHasItsBaseline() {
        for state in ["NY", "CA", "CO", "MA", "OR", "TX", "DC", "MD", "VA"] {
            let base = db.baseline(scope: state)
            XCTAssertNotNil(base, "missing state baseline for \(state)")
            XCTAssertEqual(base?.displayName, state)
            XCTAssertNotNil(base?.incomeMedian, "\(state) baseline has no income")
            XCTAssertNotNil(base?.precinctCount, "\(state) baseline predates precinct_count")
        }
    }

    func testCountyAndMetroBaselinesShipped() {
        XCTAssertNotNil(db.baseline(scope: "county|NY|Brooklyn"))
        XCTAssertNotNil(db.baseline(scope: "county|CO|Denver"))
        XCTAssertNotNil(db.baseline(scope: "county|OR|Clackamas"))
        XCTAssertNotNil(db.baseline(scope: "county|TX|Harris"))
        XCTAssertNotNil(db.baseline(scope: "metro|NY|New York City"))
        XCTAssertNil(db.baseline(scope: "county|NY|Nowhere"), "an unknown county should not resolve")
    }

    func testDMVAggregateBaselineIsPersistedAsARegionScope() {
        guard let baseline = db.baseline(scope: "region|DMV") else {
            return XCTFail("missing persisted DMV region baseline")
        }
        XCTAssertGreaterThan(baseline.precinctCount ?? 0, 0)
        XCTAssertGreaterThan(baseline.popTotal ?? 0, 0)
        XCTAssertEqual(baseline.displayName, "DMV (DC, MD, VA)")
    }

    func testGreaterWashingtonByNumbersOverviewAggregatesAllJurisdictions() {
        let overview = db.scopeOverview(region: .dmvCore)
        XCTAssertEqual(overview.precinctCount, 1310)
        XCTAssertGreaterThan(overview.totalPopulation ?? 0, 5_000_000)
        XCTAssertNotNil(overview.avgDemShare)
        XCTAssertGreaterThan(overview.leanBuckets.reduce(0) { $0 + $1.count }, 100)
    }

    /// The whole point of recomputing every scope with one method: a county and its state have to
    /// be the same kind of number, or "vs Brooklyn" and "vs NY" cannot be compared to each other.
    func testEveryScopeReportsTheSameFieldsInPlausibleRanges() {
        for scope in ["NY", "county|NY|Brooklyn", "metro|NY|New York City", "county|TX|Harris"] {
            guard let b = db.baseline(scope: scope) else {
                XCTFail("missing baseline \(scope)"); continue
            }
            XCTAssertGreaterThan(b.incomeMedian ?? 0, 10_000, "\(scope) income implausible")
            XCTAssertLessThan(b.incomeMedian ?? .max, 300_000, "\(scope) income implausible")
            for (name, value) in [("BA", b.pctBachelorsOrHigher), ("renter", b.pctRenter),
                                  ("white", b.pctWhite), ("lean", b.leanDemShare)] {
                guard let value else { continue }
                XCTAssertTrue((0...1).contains(value), "\(scope) \(name) out of 0...1: \(value)")
            }
            XCTAssertGreaterThan(b.avgAge ?? 0, 15, "\(scope) median age implausible")
            XCTAssertLessThan(b.avgAge ?? 100, 70, "\(scope) median age implausible")
        }
    }

    func testBoroughsAreDemocraticAndLassenIsNot() {
        // A cheap sanity check that the rows are not shuffled: NYC is heavily Dem, and Lassen is
        // the most Republican county in California.
        XCTAssertGreaterThan(db.baseline(scope: "metro|NY|New York City")?.leanDemShare ?? 0, 0.65)
        XCTAssertLessThan(db.baseline(scope: "county|CA|Lassen")?.leanDemShare ?? 1, 0.35)
    }

    // MARK: comparisonAreas

    func testABoroughPrecinctIsOfferedCountyThenMetroThenState() {
        guard let p = profile(state: "NY", borough: "Brooklyn") else {
            return XCTFail("no Brooklyn precinct resolved")
        }
        let areas = db.comparisonAreas(for: p)
        XCTAssertEqual(areas.map(\.scope),
                       ["county|NY|\(p.borough)", "metro|NY|New York City", "NY"],
                       "areas should run narrowest to widest")
    }

    func testANonMetroPrecinctIsOfferedCountyAndStateOnly() {
        guard let p = profile(state: "TX", borough: "Harris") else {
            return XCTFail("no Harris County precinct resolved")
        }
        let areas = db.comparisonAreas(for: p)
        XCTAssertEqual(areas.map(\.scope), ["county|TX|\(p.borough)", "TX"])
    }

    func testElectionNullProfilesStillResolveCountyAndStateComparisons() throws {
        for (unitID, state, county) in [
            ("41005-:-X000", "OR", "Clackamas"),
            ("08005-:-4276103350", "CO", "Arapahoe"),
        ] {
            let profile = try XCTUnwrap(db.precinct(unitID: unitID)?.profile)
            XCTAssertNil(profile.leanDemShare)
            XCTAssertEqual(profile.state, state)
            XCTAssertEqual(profile.borough, county)
            XCTAssertEqual(db.comparisonAreas(for: profile).map(\.scope),
                           ["county|\(state)|\(county)", state])
        }
    }

    /// The rural case, and the reason the floor exists: in a county with a handful of precincts
    /// the precinct IS most of the baseline, so comparing to it says nothing.
    func testATinyCountyFallsBackToTheStateAlone() {
        let tiny = PrecinctProfile(
            unitID: "tiny", borough: "Loving", state: "TX", precinctName: "1",
            leanLabel: nil, leanDemShare: 0.5, prevDemShare: nil, leanYear: 2024, prevYear: nil,
            leanShift: nil, leanVotes: 10, turnoutEst: nil,
            popTotal: 50, vapTotal: nil, cvap: nil,
            pctWhite: nil, pctBlack: nil, pctHispanic: nil, pctAsian: nil, pctNative: nil,
            pctPacific: nil, pctOther: nil, pluralityGroup: nil, pctNoHS: nil, pctHS: nil,
            pctBachelors: nil, pctGraduate: nil, pctBachelorsOrHigher: nil, incomeMedian: nil,
            popDensity: nil, avgAge: nil, pctRenter: nil, pctOwner: nil, dataComplete: true)
        XCTAssertNotNil(db.baseline(scope: "county|TX|Loving"), "the row should exist...")
        XCTAssertEqual(db.comparisonAreas(for: tiny).map(\.scope), ["TX"],
                       "...but it should not be offered as a comparison")
    }

    func testTheStateIsAlwaysOfferedSoTheListIsNeverEmpty() {
        for (state, borough) in [
            ("NY", "Brooklyn"), ("CA", "San Francisco"), ("CO", "Denver"),
            ("OR", "Clackamas"), ("TX", "Harris"),
        ] {
            guard let p = profile(state: state, borough: borough) else { continue }
            let areas = db.comparisonAreas(for: p)
            XCTAssertFalse(areas.isEmpty)
            XCTAssertEqual(areas.last?.scope, state, "the widest option should be the state")
        }
    }
}
