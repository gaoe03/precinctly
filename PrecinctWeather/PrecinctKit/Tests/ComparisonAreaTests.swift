import Foundation
import XCTest
@testable import PrecinctKit

/// Covers the "compare this precinct to somewhere useful" feature. The rule these tests exist to
/// protect: a label must always name the area actually used, never the area the reader asked for,
/// because those differ wherever the county is too small to mean anything.
final class ComparisonAreaTests: XCTestCase {

    private func profile(state: String, borough: String, name: String? = "1", unitID: String? = nil) -> PrecinctProfile {
        PrecinctProfile(
            unitID: unitID ?? "\(state)-\(borough)-\(name ?? "x")", borough: borough, state: state,
            precinctName: name,
            leanLabel: nil, leanDemShare: 0.5, prevDemShare: nil,
            leanYear: 2024, prevYear: nil, leanShift: nil, leanVotes: 500, turnoutEst: 0.4,
            popTotal: 1000, vapTotal: nil, cvap: nil,
            pctWhite: nil, pctBlack: nil, pctHispanic: nil, pctAsian: nil,
            pctNative: nil, pctPacific: nil, pctOther: nil, pluralityGroup: nil,
            pctNoHS: nil, pctHS: nil, pctBachelors: nil, pctGraduate: nil,
            pctBachelorsOrHigher: nil, incomeMedian: nil, popDensity: nil,
            avgAge: nil, pctRenter: nil, pctOwner: nil, dataComplete: true)
    }

    private func baseline(_ scope: String, precincts: Int?) -> Baseline {
        Baseline(scope: scope, pctWhite: nil, pctBlack: nil, pctHispanic: nil, pctAsian: nil,
                 pctBachelorsOrHigher: nil, incomeMedian: nil, pctRenter: nil, avgAge: nil,
                 leanDemShare: nil, precinctCount: precincts)
    }

    // MARK: Scope keys

    func testScopeKeysMatchTheKeysTheDatabaseIsWrittenWith() {
        let brooklyn = profile(state: "NY", borough: "Brooklyn")
        XCTAssertEqual(ComparisonArea.state.scopeKey(for: brooklyn), "NY")
        XCTAssertEqual(ComparisonArea.county.scopeKey(for: brooklyn), "county|NY|Brooklyn")
        XCTAssertEqual(ComparisonArea.metro.scopeKey(for: brooklyn), "metro|NY|New York City")
    }

    func testDMVCoreUsesAnExplicitRegionScopeAndNeverPretendsToBeAState() {
        let dc = profile(state: "DC", borough: "District of Columbia", name: "0001", unitID: "11001-0001")
        XCTAssertEqual(ComparisonArea.region.scopeKey(for: dc), "region|DMV")
        XCTAssertEqual(ComparisonArea.state.scopeKey(for: dc), "DC")

        let texas = profile(state: "TX", borough: "Harris", name: "48001-0001")
        XCTAssertNil(ComparisonArea.region.scopeKey(for: texas))
        XCTAssertTrue(CoverageRegion.dmvCore.contains(dc))
        XCTAssertFalse(CoverageRegion.dmvCore.contains(texas))
    }

    func testDMVRegionDisplayNameIsCompactAndStable() {
        XCTAssertEqual(baseline("region|DMV", precincts: 100).displayName, "DMV (DC, MD, VA)")
        XCTAssertEqual(CoverageRegion.dmvCore.shortName, "DMV (DC, MD, VA)")
        XCTAssertTrue(CoverageRegion.dmvCore.isAggregate)
    }

    func testOnlyTheFiveBoroughsBelongToTheNewYorkCityMetro() {
        for borough in ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"] {
            XCTAssertEqual(Metro.containing(profile(state: "NY", borough: borough)), "New York City",
                           "\(borough) should be in the NYC metro")
        }
        // Upstate is New York but not New York City.
        XCTAssertNil(Metro.containing(profile(state: "NY", borough: "Erie")))
        // A same-named county in another state must not be swept in.
        XCTAssertNil(Metro.containing(profile(state: "CA", borough: "Queens")))
        XCTAssertNil(ComparisonArea.metro.scopeKey(for: profile(state: "TX", borough: "Harris")))
    }

    // MARK: Display names

    func testDisplayNameShortensEachScopeForACaptionSizedLabel() {
        XCTAssertEqual(baseline("NY", precincts: nil).displayName, "NY")
        XCTAssertEqual(baseline("county|NY|Brooklyn", precincts: nil).displayName, "Brooklyn")
        XCTAssertEqual(baseline("county|CA|San Bernardino", precincts: nil).displayName, "San Bernardino")
        // The full name is too long to sit under a stat, so the metro gets an abbreviation.
        XCTAssertEqual(baseline("metro|NY|New York City", precincts: nil).displayName, "NYC")
    }

    func testDisplayNameFallsBackToTheRawScopeRatherThanCrashingOnAnUnknownShape() {
        XCTAssertEqual(baseline("something|weird", precincts: nil).displayName, "something|weird")
        XCTAssertEqual(baseline("", precincts: nil).displayName, "")
    }

    // MARK: The meaningfulness floor

    func testAreasSmallerThanTheFloorAreNotWorthComparingAgainst() {
        XCTAssertFalse(baseline("county|TX|Loving", precincts: 2).isMeaningful)
        XCTAssertFalse(baseline("county|MA|Nantucket", precincts: 1).isMeaningful)
        XCTAssertFalse(baseline("county|TX|X", precincts: Baseline.meaningfulPrecinctCount - 1).isMeaningful)
        XCTAssertTrue(baseline("county|TX|X", precincts: Baseline.meaningfulPrecinctCount).isMeaningful)
        XCTAssertTrue(baseline("county|NY|Brooklyn", precincts: 1721).isMeaningful)
    }

    func testADatabaseWithoutTheCountColumnIsTreatedAsMeaningful() {
        // Older DBs predate apply_area_baselines.py adding precinct_count. Assuming meaningful
        // keeps those readable rather than collapsing every comparison to statewide.
        XCTAssertTrue(baseline("county|NY|Brooklyn", precincts: nil).isMeaningful)
    }
}
