import Foundation
import XCTest
@testable import PrecinctKit

final class PrecinctProfileTests: XCTestCase {
    func testCountyDisplayDoesNotDuplicateOrMisnameKnownSuffixes() {
        XCTAssertEqual(countyDisplay("Manhattan"), "Manhattan")
        XCTAssertEqual(countyDisplay("Orange"), "Orange County")
        XCTAssertEqual(countyDisplay("Orange County"), "Orange County")
        XCTAssertEqual(countyDisplay("Baltimore City"), "Baltimore City")
        XCTAssertEqual(countyDisplay("North Slope Borough"), "North Slope Borough")
        XCTAssertEqual(countyDisplay(""), "")
    }

    func testPrecinctIdentifierFormatting() {
        XCTAssertEqual(precinctDisplayName("000056"), "56")
        XCTAssertEqual(precinctDisplayName("000000"), "0")
        XCTAssertEqual(precinctDisplayName("12A"), "12A")
        XCTAssertEqual(precinctTitleDisplay("000056"), "Precinct 56")
        XCTAssertEqual(precinctTitleDisplay("Chatham Town Precinct 1"), "Chatham Town Precinct 1")
    }

    func testLeanShortRoundingBoundaries() {
        XCTAssertEqual(profile(share: nil).leanShort, "—")
        XCTAssertEqual(profile(share: 0.5).leanShort, "Even")
        XCTAssertEqual(profile(share: 0.502).leanShort, "Even")
        XCTAssertEqual(profile(share: 0.504).leanShort, "D +1")
        XCTAssertEqual(profile(share: 0).leanShort, "R +100")
        XCTAssertEqual(profile(share: 1).leanShort, "D +100")
    }

    func testRaceBreakdownFiltersNonPositiveValuesAndSortsDescending() {
        let value = profile(share: 0.5, white: 0.2, black: 0, hispanic: 0.4, asian: -0.1)
        XCTAssertEqual(value.raceBreakdown.map(\.label), ["Hispanic", "White"])
        XCTAssertEqual(value.raceBreakdown.map(\.value), [0.4, 0.2])
    }

    func testProfileCodableRoundTripPreservesOptionalFields() throws {
        let original = profile(share: nil, white: nil, black: 0.25, hispanic: nil, asian: nil)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PrecinctProfile.self, from: encoded), original)
    }

    private func profile(share: Double?, white: Double? = nil, black: Double? = nil,
                         hispanic: Double? = nil, asian: Double? = nil) -> PrecinctProfile {
        PrecinctProfile(
            unitID: "test", borough: "Orange", state: "CA", precinctName: "000056",
            leanLabel: nil, leanDemShare: share, prevDemShare: nil,
            leanYear: nil, prevYear: nil, leanShift: nil, leanVotes: nil, turnoutEst: nil,
            popTotal: nil, vapTotal: nil, cvap: nil,
            pctWhite: white, pctBlack: black, pctHispanic: hispanic,
            pctAsian: asian, pctNative: nil, pctPacific: nil, pctOther: nil,
            pluralityGroup: nil, pctNoHS: nil, pctHS: nil, pctBachelors: nil,
            pctGraduate: nil, pctBachelorsOrHigher: nil, incomeMedian: nil,
            popDensity: nil, avgAge: nil, pctRenter: nil, pctOwner: nil,
            dataComplete: false
        )
    }
}
