import XCTest
@testable import PrecinctKit

/// Checks By the Numbers against numbers computed outside the app.
///
/// Every expected value below comes from an independent Python pass over the bundled
/// nyc_precincts.sqlite, opened read-only (verify_numbers.py for the raw audit, verify_round6.py for
/// the corrected rules). The script pulls raw rows and does the binning, strict lower and higher
/// counts, (value DESC/ASC, unit_id) extremes, 1e-9 ties, shift year pairs, the vote-weighted
/// overview share and the reader sentences in Python, without reusing the app's SQL or Swift.
/// The corrected rules it encodes:
/// - turnout uses the displayed whole percent, round(min(turnout_est, 1) * 100) / 100, for bins,
///   ranking, ties and percentile, raw filter <= 1.05
/// - lean uses the share snapped to the printed margin, 0.5 + round((share - 0.5) * 200) / 200,
///   binned on the whole margin (30 and 10), for bins, ranking, ties, percentile and the sentence
/// - college and renters use round(x * 100) / 100, age uses round(avg_age), density uses whole
///   people below 999.5 and the nearest 100 above, each the number as printed. Income is exact.
/// - shift is whole margin points, the rounded later margin minus the rounded earlier margin, used
///   for bins (5 and 15), ranking, ties and percentile, and the format names the direction
/// - percentile sentences clamp to 1..99 and say "the highest" or "the lowest" at the ends
/// - swing sentences count strictly both ways, and their points always sit inside their bar
/// - the overview lean is the vote-weighted two-party share of each precinct's latest election
/// If the database is rebuilt, rerun the script and update these numbers.
final class DistributionsVerificationTests: XCTestCase {
    private let db = PrecinctDB.shared
    private let queens1322 = "36081-:-36081001322"
    private let dmv = ["11001", "24031", "24033", "51013", "51510", "51059", "51600", "51610",
                       "51107", "51153", "51683", "51685"]

    private func profile(_ unitID: String) -> PrecinctProfile? { db.precinct(unitID: unitID)?.profile }

    // MARK: distribution() and the sentence under each chart

    func testNewYorkStatewideWithQueens1322() {
        let prof = profile(queens1322)
        let lean = db.distribution(.lean, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(lean.counts, [5107, 1881, 2223, 2316, 1907])
        XCTAssertEqual(lean.total, 13434)
        XCTAssertEqual(lean.selectedBucket, 3)
        XCTAssertEqual(lean.selectedValue ?? .nan, 0.45, accuracy: 1e-9)
        XCTAssertEqual(lean.selectedPercentile ?? .nan, 4080.0 / 13434.0, accuracy: 1e-9)
        XCTAssertEqual(lean.youSentence(place: "PLACE", scope: "New York"), "PLACE is R+10, in the Lean R group.")

        let shift = db.distribution(.shift, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(shift.counts, [50, 484, 3856, 5444, 3596])
        XCTAssertEqual(shift.total, 13430)
        XCTAssertEqual(shift.selectedBucket, 4)
        XCTAssertEqual(shift.selectedValue ?? .nan, -46, accuracy: 1e-12)
        XCTAssertEqual(shift.selectedPercentile ?? .nan, 99.0 / 13430.0, accuracy: 1e-9)
        XCTAssertEqual(shift.selectedAbove ?? .nan, 13313.0 / 13430.0, accuracy: 1e-9)
        XCTAssertEqual(Metric.shift.format(shift.selectedValue ?? 0), "46 points toward R")
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "New York", profile: prof),
                       "PLACE swung 46 points toward Republicans, from D+36 in 2020 to R+10 in 2024. Only 1% of precincts in New York swung further toward Republicans.")
        XCTAssertEqual((0..<5).map { shift.percentLabel(bucket: $0) }, ["<1%", "4%", "29%", "41%", "27%"])

        let turnout = db.distribution(.turnout, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(turnout.counts, [1634, 3148, 3459, 3238, 1569])
        XCTAssertEqual(turnout.total, 13048)
        XCTAssertEqual(turnout.selectedBucket, 0)
        XCTAssertEqual(turnout.selectedValue ?? .nan, 0.26, accuracy: 1e-12)
        XCTAssertEqual(turnout.selectedPercentile ?? .nan, 148.0 / 13048.0, accuracy: 1e-9)
        XCTAssertEqual(turnout.youSentence(place: "PLACE", scope: "New York"),
                       "PLACE had 26% turnout, lower than 99% of precincts in New York.")

        let group = db.distribution(.largestGroup, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(group.counts, [9138, 1714, 1535, 605, 21])
        XCTAssertEqual(group.selectedBucket, 1)
        XCTAssertNil(group.selectedValue)
        XCTAssertEqual(group.percentLabel(bucket: 4), "<1%")
        XCTAssertEqual(group.youSentence(place: "PLACE", scope: "New York"), "In PLACE, the largest group is Hispanic.")

        let income = db.distribution(.income, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(income.counts, [1803, 3089, 2890, 3286, 1938])
        XCTAssertEqual(income.selectedPercentile ?? .nan, 865.0 / 13006.0, accuracy: 1e-9)
        XCTAssertEqual(income.youSentence(place: "PLACE", scope: "New York"),
                       "PLACE has a median household income of $37,654, lower than 93% of precincts in New York.")

        let college = db.distribution(.college, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(college.counts, [2196, 4899, 3429, 1689, 800])
        XCTAssertEqual(college.selectedValue ?? .nan, 0.10, accuracy: 1e-12)
        XCTAssertEqual(college.selectedPercentile ?? .nan, 431.0 / 13013.0, accuracy: 1e-9)
        XCTAssertEqual(college.youSentence(place: "PLACE", scope: "New York"),
                       "In PLACE, 10% of adults have a college degree, lower than 96% of precincts in New York.")

        let renters = db.distribution(.renters, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(renters.counts, [4330, 2753, 1964, 1865, 2094])
        XCTAssertEqual(renters.selectedPercentile ?? .nan, 11003.0 / 13006.0, accuracy: 1e-9)
        XCTAssertEqual(renters.youSentence(place: "PLACE", scope: "New York"),
                       "In PLACE, 81% of homes are rented, higher than 85% of precincts in New York.")

        // 35.1 prints as 35, and 473 precincts print 35, so strict-lower is 2220.
        let age = db.distribution(.age, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(age.counts, [658, 1562, 2812, 3251, 4730])
        XCTAssertEqual(age.selectedValue ?? .nan, 35, accuracy: 1e-12)
        XCTAssertEqual(age.selectedPercentile ?? .nan, 2220.0 / 13013.0, accuracy: 1e-9)
        XCTAssertEqual(age.youSentence(place: "PLACE", scope: "New York"),
                       "PLACE has a median age of 35, lower than 79% of precincts in New York.")

        let density = db.distribution(.density, state: "NY", county: nil, selectedUnitID: queens1322)
        XCTAssertEqual(density.counts, [2648, 2889, 2977, 1607, 2892])
        XCTAssertEqual(density.selectedValue ?? .nan, 63900, accuracy: 1e-9)
        XCTAssertEqual(density.youSentence(place: "PLACE", scope: "New York"),
                       "PLACE has 63.9k people per square mile, higher than 83% of precincts in New York.")
    }

    func testQueensCounty() {
        let prof = profile(queens1322)
        let shift = db.distribution(.shift, state: "NY", county: "Queens", selectedUnitID: queens1322)
        XCTAssertEqual(shift.counts, [9, 11, 60, 324, 842])
        XCTAssertEqual(shift.total, 1246)
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "Queens", profile: prof),
                       "PLACE swung 46 points toward Republicans, from D+36 in 2020 to R+10 in 2024. Only 4% of precincts in Queens swung further toward Republicans.")

        // Was "higher than 0%": 4 of 1239 is below 1%, so the clamp says 1%.
        let turnout = db.distribution(.turnout, state: "NY", county: "Queens", selectedUnitID: queens1322)
        XCTAssertEqual(turnout.counts, [216, 626, 298, 70, 29])
        XCTAssertEqual(turnout.youSentence(place: "PLACE", scope: "Queens"),
                       "PLACE had 26% turnout, lower than 99% of precincts in Queens.")

        let density = db.distribution(.density, state: "NY", county: "Queens", selectedUnitID: queens1322)
        XCTAssertEqual((0..<5).map { density.percentLabel(bucket: $0) }, ["<1%", "2%", "22%", "45%", "32%"])

        // Queens 322 moved 1 point right while 97% moved further right: no "Only", "1 point".
        let q322 = "36081-:-36081000322"
        let s322 = db.distribution(.shift, state: "NY", county: "Queens", selectedUnitID: q322)
        XCTAssertEqual(s322.selectedBucket, 2)
        XCTAssertEqual(s322.youSentence(place: "PLACE", scope: "Queens", profile: profile(q322)),
                       "PLACE swung 1 point toward Republicans, from R+1 in 2020 to R+2 in 2024. In Queens, 96% of precincts swung further toward Republicans.")
        // 35 precincts share 56%, so strict-lower is 879 of 1239.
        let t322 = db.distribution(.turnout, state: "NY", county: "Queens", selectedUnitID: q322)
        XCTAssertEqual(t322.youSentence(place: "PLACE", scope: "Queens"), "PLACE had 56% turnout, higher than 71% of precincts in Queens.")
    }

    func testGreeneSwingMatchesPrintedMargins() {
        // Raw change is 11.3 points, the printed margins are R+24 and R+36: the value is 12.
        let unit = "36039-:-36039000024"
        let shift = db.distribution(.shift, state: "NY", county: "Greene", selectedUnitID: unit)
        XCTAssertEqual(shift.counts, [1, 3, 31, 6, 1])
        XCTAssertEqual(shift.selectedValue ?? .nan, -12, accuracy: 1e-12)
        XCTAssertEqual(shift.selectedBucket, 3)
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "Greene", profile: profile(unit)),
                       "PLACE swung 12 points toward Republicans, from R+24 in 2020 to R+36 in 2024. Only 2% of precincts in Greene swung further toward Republicans.")
        // Nothing is younger, so the sentence names the end instead of "higher than 0%".
        let age = db.distribution(.age, state: "NY", county: "Greene", selectedUnitID: unit)
        XCTAssertEqual(age.youSentence(place: "PLACE", scope: "Greene"), "PLACE has a median age of 32, the lowest in Greene.")
    }

    func testCaliforniaWithAlameda547720() {
        let unit = "06001-:-06001547720"
        let income = db.distribution(.income, state: "CA", county: nil, selectedUnitID: unit)
        XCTAssertEqual(income.counts, [894, 2684, 3226, 4320, 2508])
        XCTAssertEqual(income.total, 13632)
        XCTAssertEqual(income.selectedValue ?? .nan, 250001, accuracy: 1e-9)
        XCTAssertEqual(income.selectedAbove ?? .nan, 0, accuracy: 1e-12)
        // Was "higher than 100%". 67 precincts share the top code.
        XCTAssertEqual(income.youSentence(place: "PLACE", scope: "California"),
                       "PLACE has a median household income of $250k+, tied for the highest in California.")

        let shift = db.distribution(.shift, state: "CA", county: nil, selectedUnitID: unit)
        XCTAssertEqual(shift.counts, [137, 896, 4430, 5444, 3760])
        XCTAssertEqual(shift.selectedBucket, 4)
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "California", profile: profile(unit)),
                       "PLACE swung 15 points toward Republicans, from D+49 in 2020 to D+34 in 2024. Only 23% of precincts in California swung further toward Republicans.")

        let college = db.distribution(.college, state: "CA", county: nil, selectedUnitID: unit)
        XCTAssertEqual(college.youSentence(place: "PLACE", scope: "California"),
                       "In PLACE, 82% of adults have a college degree, higher than 98% of precincts in California.")

        let density = db.distribution(.density, state: "CA", county: nil, selectedUnitID: unit)
        XCTAssertEqual(density.percentLabel(bucket: 4), "<1%")

        // No California row has a turnout estimate. The screen shows a note instead of a chart.
        let turnout = db.distribution(.turnout, state: "CA", county: nil, selectedUnitID: unit)
        XCTAssertEqual(turnout.counts, [0, 0, 0, 0, 0])
        XCTAssertEqual(turnout.total, 0)
        XCTAssertNil(turnout.selectedBucket)
        XCTAssertNil(turnout.youSentence(place: "PLACE", scope: "California"))
    }

    func testOregonWithBenton12() {
        let unit = "41003-:-0012"
        let shift = db.distribution(.shift, state: "OR", county: nil, selectedUnitID: unit)
        // Raw change 14.1, printed margins D+5 and D+20: 15 points, so the bar is "Toward D, 15+".
        XCTAssertEqual(shift.counts, [61, 588, 520, 42, 3])
        XCTAssertEqual(shift.selectedBucket, 0)
        // 42 higher, strictly. The old 1 - p counted the precinct itself.
        XCTAssertEqual(shift.selectedAbove ?? .nan, 42.0 / 1214.0, accuracy: 1e-9)
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "Oregon", profile: profile(unit)),
                       "PLACE swung 15 points toward Democrats, from D+5 in 2016 to D+20 in 2020. Only 3% of precincts in Oregon swung further toward Democrats.")

        // Raw 1.029 shows as 100% and ties with the 54 others shown as 100%.
        let turnout = db.distribution(.turnout, state: "OR", county: nil, selectedUnitID: unit)
        XCTAssertEqual(turnout.counts, [4, 35, 201, 502, 399])
        XCTAssertEqual(turnout.selectedBucket, 4)
        XCTAssertEqual(turnout.selectedValue ?? .nan, 1.0, accuracy: 1e-12)
        XCTAssertEqual(turnout.selectedPercentile ?? .nan, 1086.0 / 1141.0, accuracy: 1e-9)
        XCTAssertEqual(turnout.selectedAbove ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(turnout.youSentence(place: "PLACE", scope: "Oregon"), "PLACE had 100% turnout, tied for the highest in Oregon.")
        XCTAssertEqual(turnout.percentLabel(bucket: 0), "<1%")

        let density = db.distribution(.density, state: "OR", county: nil, selectedUnitID: unit)
        XCTAssertEqual((0..<5).map { density.percentLabel(bucket: $0) }, ["57%", "42%", "<1%", "0%", "0%"])

        let group = db.distribution(.largestGroup, state: "OR", county: nil, selectedUnitID: unit)
        XCTAssertEqual(group.counts, [1037, 20, 0, 3, 2])
    }

    func testDMVRegionByPrefix() {
        let unit = "11001-:-0001"
        let lean = db.distribution(.lean, state: "DMV", county: nil, prefixes: dmv, selectedUnitID: unit)
        XCTAssertEqual(lean.counts, [999, 206, 52, 10, 1])
        XCTAssertEqual(lean.selectedBucket, 0)
        XCTAssertEqual(lean.selectedValue ?? .nan, 0.95, accuracy: 1e-9)
        XCTAssertEqual(lean.youSentence(place: "PLACE", scope: "DMV"), "PLACE is D+90, in the Solid D group.")

        let shift = db.distribution(.shift, state: "DMV", county: nil, prefixes: dmv, selectedUnitID: unit)
        XCTAssertEqual(shift.counts, [23, 89, 521, 458, 176])
        XCTAssertEqual(shift.youSentence(place: "PLACE", scope: "DMV", profile: profile(unit)),
                       "PLACE voted almost the same as the election before.")

        // DC 0001 has raw turnout 1.08, above the 1.05 filter, so it is not marked.
        let turnout = db.distribution(.turnout, state: "DMV", county: nil, prefixes: dmv, selectedUnitID: unit)
        XCTAssertEqual(turnout.counts, [14, 111, 281, 415, 376])
        XCTAssertNil(turnout.selectedBucket)

        let income = db.distribution(.income, state: "DMV", county: nil, prefixes: dmv, selectedUnitID: unit)
        XCTAssertEqual(income.counts, [47, 129, 213, 444, 405])
        XCTAssertEqual(income.youSentence(place: "PLACE", scope: "DMV"), "PLACE has a median household income of $88,323, lower than 77% of precincts in DMV.")

        let density = db.distribution(.density, state: "DMV", county: nil, prefixes: dmv, selectedUnitID: unit)
        XCTAssertEqual(density.youSentence(place: "PLACE", scope: "DMV"), "PLACE has 10.9k people per square mile, higher than 97% of precincts in DMV.")
    }

    // MARK: ranked(), tieCount(), extreme titles

    func testExtremesTitlesAndTies() {
        func ends(_ m: Metric, _ state: String, _ county: String?, _ prefixes: [String] = []) -> (RankedPrecinct?, RankedPrecinct?) {
            (db.ranked(m, state: state, county: county, prefixes: prefixes, bucket: nil, ascending: false, limit: 1).first,
             db.ranked(m, state: state, county: county, prefixes: prefixes, bucket: nil, ascending: true, limit: 1).first)
        }

        let (nyHigh, nyLow) = ends(.lean, "NY", nil)
        XCTAssertEqual(nyHigh?.unitID, "36047-:-36047001008")
        XCTAssertEqual(nyLow?.unitID, "36087-:-36087000189")
        XCTAssertEqual(Metric.lean.extremeTitle(highest: true, value: nyHigh?.value), "Most Democratic")
        XCTAssertEqual(Metric.lean.extremeTitle(highest: false, value: nyLow?.value), "Most Republican")
        // D+96 and R+100 are each printed by two NY precincts, so both ends are ties.
        XCTAssertEqual(db.tieCount(.lean, value: nyHigh?.value ?? 0, state: "NY", county: nil), 2)
        XCTAssertEqual(db.tieCount(.lean, value: nyLow?.value ?? 1, state: "NY", county: nil), 2)

        // Manhattan's most Republican precinct is D+6.
        let (_, mnLow) = ends(.lean, "NY", "Manhattan")
        XCTAssertEqual(mnLow?.unitID, "36061-:-36061000025")
        XCTAssertEqual(Metric.lean.format(mnLow?.value ?? 0), "D+6")
        XCTAssertEqual(Metric.lean.extremeTitle(highest: false, value: mnLow?.value), "Least Democratic")

        let (nyShiftHigh, nyShiftLow) = ends(.shift, "NY", nil)
        XCTAssertEqual(nyShiftHigh?.unitID, "36047-:-36047000266")
        XCTAssertEqual(Metric.shift.format(nyShiftHigh?.value ?? 0), "66 points toward D")
        XCTAssertEqual(nyShiftLow?.unitID, "36047-:-36047000181")
        XCTAssertEqual(Metric.shift.format(nyShiftLow?.value ?? 0), "120 points toward R")

        // Every El Paso precinct swung right: the high end is the smallest swing toward R.
        let (epHigh, epLow) = ends(.shift, "TX", "El Paso")
        XCTAssertEqual(epHigh?.unitID, "48141-:-48141000088")
        XCTAssertEqual(Metric.shift.format(epHigh?.value ?? 0), "3 points toward R")
        XCTAssertEqual(Metric.shift.extremeTitle(highest: true, value: epHigh?.value), "Smallest swing toward R")
        XCTAssertEqual(Metric.shift.extremeTitle(highest: false, value: epLow?.value), "Biggest swing toward R")

        // Every Deschutes precinct swung left.
        let (deHigh, deLow) = ends(.shift, "OR", "Deschutes")
        XCTAssertEqual(deLow?.unitID, "41017-:-0024")
        XCTAssertEqual(Metric.shift.format(deLow?.value ?? 0), "3 points toward D")
        XCTAssertEqual(Metric.shift.extremeTitle(highest: true, value: deHigh?.value), "Biggest swing toward D")
        XCTAssertEqual(Metric.shift.extremeTitle(highest: false, value: deLow?.value), "Smallest swing toward D")
        XCTAssertEqual(Metric.shift.format(1), "1 point toward D")
        XCTAssertEqual(Metric.shift.format(0), "No change")
        // Oregon's biggest swing toward R is a tie at 17 points.
        let (_, orShiftLow) = ends(.shift, "OR", nil)
        XCTAssertEqual(orShiftLow?.value ?? .nan, -17, accuracy: 1e-12)
        XCTAssertEqual(db.tieCount(.shift, value: -17, state: "OR", county: nil), 2)
        XCTAssertEqual(Metric.income.extremeTitle(highest: true, value: 1), "Highest")

        // Turnout is the displayed percent, so the top is a tie of every precinct shown as 100%.
        let (nyTurnHigh, _) = ends(.turnout, "NY", nil)
        XCTAssertEqual(nyTurnHigh?.unitID, "36001-:-36001000202")
        XCTAssertEqual(nyTurnHigh?.value ?? .nan, 1.0, accuracy: 1e-12)
        XCTAssertEqual(db.tieCount(.turnout, value: 1.0, state: "NY", county: nil), 183)
        XCTAssertEqual(db.tieCount(.turnout, value: 1.0, state: "OR", county: nil), 55)
        XCTAssertEqual(db.tieCount(.turnout, value: 1.0, state: "DMV", county: nil, prefixes: dmv), 54)
        XCTAssertEqual(db.tieCount(.turnout, value: 1.0, state: "NY", county: "Manhattan"), 15)
        // The lowest NY turnout shows as 6% and two precincts show 6%.
        let (_, nyTurnLow) = ends(.turnout, "NY", nil)
        XCTAssertEqual(nyTurnLow?.unitID, "36055-:-36055000648")
        XCTAssertEqual(nyTurnLow?.value ?? .nan, 0.06, accuracy: 1e-12)
        XCTAssertEqual(db.tieCount(.turnout, value: nyTurnLow?.value ?? 0, state: "NY", county: nil), 2)

        XCTAssertEqual(db.tieCount(.income, value: 250001, state: "NY", county: nil), 166)
        XCTAssertEqual(db.tieCount(.income, value: 250001, state: "CA", county: nil), 67)
        // Ties count every precinct printed with the same number: 10 NY precincts show 100%
        // college (8 were exactly 1.0 before), 395 show 100% renters (366 before).
        XCTAssertEqual(db.tieCount(.college, value: 1, state: "NY", county: nil), 10)
        XCTAssertEqual(db.tieCount(.college, value: 0, state: "NY", county: nil), 18)
        XCTAssertEqual(db.tieCount(.renters, value: 1, state: "NY", county: nil), 395)
        XCTAssertEqual(db.tieCount(.renters, value: 0, state: "NY", county: nil), 330)
        let (nyAgeHigh, _) = ends(.age, "NY", nil)
        XCTAssertEqual(nyAgeHigh?.unitID, "36059-:-36059000288")
        XCTAssertEqual(db.tieCount(.age, value: nyAgeHigh?.value ?? 0, state: "NY", county: nil), 2)
        let (_, orDensityLow) = ends(.density, "OR", nil)
        XCTAssertEqual(orDensityLow?.unitID, "41019-:-0002")
        XCTAssertEqual(db.tieCount(.density, value: orDensityLow?.value ?? -1, state: "OR", county: nil), 8)
        let (_, mnDensityLow) = ends(.density, "NY", "Manhattan")
        XCTAssertEqual(Metric.density.format(mnDensityLow?.value ?? 0), "1.5k")

        // Density text comes from the same rounding as its value: 999.6 is "1k", not "1000",
        // an exact 1450 is "1.5k" as SQLite ROUND gives, and 4983.8 is "5k" in the "5k to 20k" bar.
        XCTAssertEqual(Metric.density.format(999.6), "1k")
        XCTAssertEqual(Metric.density.format(1450), "1.5k")
        XCTAssertEqual(Metric.density.format(63943.459143117216), "63.9k")
        XCTAssertEqual(Metric.density.format(855.9558852460368), "856")
        XCTAssertEqual(db.tieCount(.income, value: 250001, state: "DMV", county: nil, prefixes: dmv), 14)
    }

    func testBinLabels() {
        XCTAssertEqual(Metric.lean.bucketDetails, ["D+30 or more", "D+10 to 29", "under 10", "R+10 to 29", "R+30 or more"])
        XCTAssertEqual(Metric.shift.bucketDetails, ["15+ points", "5 to 14", "under 5", "5 to 14", "15+ points"])
    }

    // MARK: lean groups

    func testLeanGroupsFollowThePrintedMargin() {
        let q = db.distribution(.lean, state: "NY", county: "Queens", selectedUnitID: nil)
        XCTAssertEqual(q.counts, [495, 314, 271, 111, 56])
        let ca = db.distribution(.lean, state: "CA", county: nil, selectedUnitID: "06001-:-06001547720")
        XCTAssertEqual(ca.counts, [5292, 3649, 3015, 1837, 1282])
        XCTAssertEqual(ca.selectedBucket, 0)
        XCTAssertEqual(ca.youSentence(place: "PLACE", scope: "California"), "PLACE is D+34, in the Solid D group.")

        // Albany 223 has share 0.5497, printed D+10. The bundled lean_label says "Even" (raw
        // threshold 0.55). The chart, the helper and the profile all put it in Lean D, because
        // PrecinctProfile.init derives the group from the printed margin.
        let unit = "36001-:-36001000223"
        let albany = db.distribution(.lean, state: "NY", county: "Albany", selectedUnitID: unit)
        XCTAssertEqual(albany.selectedBucket, 1)
        XCTAssertEqual(albany.youSentence(place: "PLACE", scope: "Albany"), "PLACE is D+10, in the Lean D group.")
        let prof = profile(unit)
        XCTAssertEqual(prof?.leanLabel, "Lean Dem")
        XCTAssertEqual(printedMargin(share: prof?.leanDemShare ?? .nan), 10)
        XCTAssertEqual(leanGroupLabel(forMargin: printedMargin(share: prof?.leanDemShare ?? .nan)), "Lean Dem")

        XCTAssertEqual([30, 29, 10, 9, 0, -9, -10, -29, -30].map(leanGroupLabel(forMargin:)),
                       ["Solid Dem", "Lean Dem", "Lean Dem", "Even", "Even", "Even", "Lean Rep", "Lean Rep", "Solid Rep"])
        XCTAssertEqual(printedMargin(share: 0.44935064935064933), -10)
    }

    // MARK: shiftYears()

    func testShiftYears() {
        let dmvPairs = db.shiftYears(state: "DMV", county: nil, prefixes: dmv)
        XCTAssertEqual(dmvPairs.map { [$0.from, $0.to, $0.count] }, [[2020, 2024, 1123], [2016, 2020, 144]])
        XCTAssertEqual(db.shiftYears(state: "OR", county: nil).map { [$0.from, $0.to, $0.count] }, [[2016, 2020, 1214]])
        XCTAssertEqual(db.shiftYears(state: "NY", county: "Queens").map { [$0.from, $0.to, $0.count] }, [[2020, 2024, 1246]])
        let ny = db.shiftYears(state: "NY", county: nil)
        XCTAssertEqual(ny.first.map { [$0.from, $0.to, $0.count] }, [2020, 2024, 13426])
        XCTAssertEqual(ny.reduce(0) { $0 + $1.count }, 13430)
    }

    // MARK: scopeOverview()

    func testOverview() {
        // avgDemShare is now the vote-weighted two-party share. Oregon was R+3 as a plain mean.
        let ny = db.scopeOverview(state: "NY")
        XCTAssertEqual(ny.precinctCount, 14011)
        XCTAssertEqual(ny.totalPopulation, 20_199_343)
        XCTAssertEqual(ny.avgDemShare ?? .nan, 0.5634687388047162, accuracy: 1e-9)
        XCTAssertEqual(Metric.lean.format(ny.avgDemShare ?? 0), "D+13")
        XCTAssertEqual(ny.medianIncome, 88088)

        let queens = db.scopeOverview(state: "NY", county: "Queens")
        XCTAssertEqual(queens.precinctCount, 1321)
        XCTAssertEqual(queens.totalPopulation, 2_404_599)
        XCTAssertEqual(queens.avgDemShare ?? .nan, 0.6229350708128211, accuracy: 1e-9)
        XCTAssertEqual(queens.medianIncome, 88590)

        let oregon = db.scopeOverview(state: "OR")
        XCTAssertEqual(oregon.precinctCount, 1300)
        XCTAssertEqual(oregon.avgDemShare ?? .nan, 0.5831107715826892, accuracy: 1e-9)
        XCTAssertEqual(Metric.lean.format(oregon.avgDemShare ?? 0), "D+17")
        XCTAssertEqual(oregon.medianIncome, 68695)

        let ca = db.scopeOverview(state: "CA")
        XCTAssertEqual(ca.precinctCount, 23910)
        XCTAssertEqual(ca.totalPopulation, 39_137_766)
        XCTAssertEqual(ca.avgDemShare ?? .nan, 0.604085721868538, accuracy: 1e-9)
        XCTAssertEqual(ca.medianIncome, 98777)

        let region = db.scopeOverview(region: .dmvCore)
        XCTAssertEqual(region.precinctCount, 1310)
        XCTAssertEqual(region.totalPopulation, 5_269_169)
        XCTAssertEqual(region.avgDemShare ?? .nan, 0.759962055824443, accuracy: 1e-9)
        XCTAssertEqual(region.medianIncome, 123423)
    }
}
