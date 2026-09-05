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

    /// The headline form used by the widgets and the share card. It exists because
    /// `precinctTitleDisplay` only prefixes all-numeric ids, which left CA's alphanumeric SOS ids
    /// reading as naked serials.
    func testPrecinctHeadlinePrefixesBareIdentifiersButNeverRealNames() {
        func named(_ name: String?) -> PrecinctProfile {
            PrecinctProfile(unitID: "u", borough: "Queens", state: "NY", precinctName: name,
                            leanLabel: nil, leanDemShare: nil, prevDemShare: nil, leanYear: nil,
                            prevYear: nil, leanShift: nil, leanVotes: nil, turnoutEst: nil,
                            popTotal: nil, vapTotal: nil, cvap: nil,
                            pctWhite: nil, pctBlack: nil, pctHispanic: nil, pctAsian: nil,
                            pctNative: nil, pctPacific: nil, pctOther: nil, pluralityGroup: nil,
                            pctNoHS: nil, pctHS: nil, pctBachelors: nil, pctGraduate: nil,
                            pctBachelorsOrHigher: nil, incomeMedian: nil, popDensity: nil,
                            avgAge: nil, pctRenter: nil, pctOwner: nil, dataComplete: false)
        }
        XCTAssertEqual(precinctHeadline(named("001320")), "Precinct 1320")
        XCTAssertEqual(precinctHeadline(named("7516")), "Precinct 7516")
        // The CA case this helper was written for: alphanumeric, one token, starts with a digit.
        XCTAssertEqual(precinctHeadline(named("1290023A")), "Precinct 1290023A")
        // Real names pass through untouched, and are never double-prefixed.
        XCTAssertEqual(precinctHeadline(named("AD 65 ED 21")), "AD 65 ED 21")
        XCTAssertEqual(precinctHeadline(named("Chatham Town Precinct 1")), "Chatham Town Precinct 1")
        XCTAssertEqual(precinctHeadline(named(nil)), "Precinct")
        XCTAssertEqual(precinctHeadline(named("")), "Precinct")
    }

    func testLeanShortRoundingBoundaries() {
        XCTAssertEqual(profile(share: nil).leanShort, "No election data")
        XCTAssertEqual(profile(share: 0.5).leanShort, "Even")
        XCTAssertEqual(profile(share: 0.502).leanShort, "Even")
        // No space after the letter. This is the form the app, the widgets, the share card and
        // the site have always shipped ("D+87"); the spaced literals here were a typo that made
        // the suite red against correct code.
        XCTAssertEqual(profile(share: 0.504).leanShort, "D+1")
        XCTAssertEqual(profile(share: 0).leanShort, "R+100")
        XCTAssertEqual(profile(share: 1).leanShort, "D+100")
    }

    func testShareCardElectionPresentationKeepsNullProfilesNeutral() {
        let missing = ShareCardElectionPresentation(profile: profile(share: nil))
        XCTAssertEqual(missing.headline, "No election data")
        XCTAssertNil(missing.detail)
        XCTAssertEqual(missing.footer, "Election data unavailable. 2020 Census and ACS.")
        XCTAssertNil(missing.voteShare)
        XCTAssertEqual(missing.tint, .neutral)
        XCTAssertFalse(missing.showsVoteBar)

        let available = ShareCardElectionPresentation(profile: .sample)
        XCTAssertEqual(available.headline, "D+36")
        XCTAssertEqual(available.detail, "Solid Dem in 2024")
        XCTAssertEqual(available.footer, "2024 presidential vote. 2020 Census and ACS.")
        XCTAssertEqual(available.voteShare, 0.681)
        XCTAssertEqual(available.tint, .partisan(0.681))
        XCTAssertTrue(available.showsVoteBar)
    }

    func testCoverageCopyIncludesOregonAndColorado() {
        XCTAssertTrue(Coverage.abbrList.contains("OR"))
        XCTAssertTrue(Coverage.abbrList.contains("CO"))
        XCTAssertTrue(Coverage.namesSentence.contains("Oregon"))
        XCTAssertTrue(Coverage.namesSentence.contains("Colorado"))
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

    func testDMVCoreUsesExplicitJurisdictionPrefixesWithoutInventingAState() {
        XCTAssertEqual(CoverageRegion.dmvCore.id, "DMV")
        XCTAssertTrue(CoverageRegion.dmvCore.isAggregate)
        XCTAssertEqual(CoverageRegion.dmvCore.jurisdictions.map(\.code), [
            "11001", "24031", "24033", "51013", "51510", "51059", "51600",
            "51610", "51107", "51153", "51683", "51685"
        ])
        XCTAssertTrue(CoverageRegion.dmvCore.contains(profile(unitID: "24031-:-001")))
        XCTAssertTrue(CoverageRegion.dmvCore.contains(profile(unitID: "51685-:-001", state: "VA")))
        XCTAssertFalse(CoverageRegion.dmvCore.contains(profile(unitID: "24005-:-001")))
    }

    private func profile(unitID: String, state: String = "MD") -> PrecinctProfile {
        PrecinctProfile(unitID: unitID, borough: "", state: state, precinctName: nil,
                        leanLabel: nil, leanDemShare: nil, prevDemShare: nil, leanYear: nil,
                        prevYear: nil, leanShift: nil, leanVotes: nil, turnoutEst: nil,
                        popTotal: nil, vapTotal: nil, cvap: nil, pctWhite: nil, pctBlack: nil,
                        pctHispanic: nil, pctAsian: nil, pctNative: nil, pctPacific: nil,
                        pctOther: nil, pluralityGroup: nil, pctNoHS: nil, pctHS: nil,
                        pctBachelors: nil, pctGraduate: nil, pctBachelorsOrHigher: nil,
                        incomeMedian: nil, popDensity: nil, avgAge: nil, pctRenter: nil,
                        pctOwner: nil, dataComplete: false)
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
