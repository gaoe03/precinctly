import CoreLocation
import Darwin
import Foundation

private struct LookupSample: Decodable {
    let mode: String
    let state: String
    let county: String
    let unitID: String?
    let longitude: Double
    let latitude: Double
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw HarnessFailure(description: message)
    }
}

private func runHarness(databasePath: String, samplesPath: String) throws -> [String: Any] {
    let databaseURL = URL(fileURLWithPath: databasePath)
    let sampleURL = URL(fileURLWithPath: samplesPath)
    let samples = try JSONDecoder().decode(
        [LookupSample].self,
        from: Data(contentsOf: sampleURL)
    )
    let database = PrecinctDB(databaseURL: databaseURL)
    try require(database.isAvailable, "PrecinctDB rejected the Phase 3 database")

    let expectedCounts = ["OR": 1_300, "CO": 3_163]
    let expectedNullCounts = ["OR": 3, "CO": 4]
    var decodedCandidateRows = 0
    var decodedRegionRows = 0

    for state in ["OR", "CO"] {
        let counties = database.counties(state: state)
        try require(counties.count == (state == "OR" ? 36 : 64),
                    "\(state) county count differs in Swift")
        try require(database.baseline(scope: state) != nil,
                    "\(state) state baseline is unreadable in Swift")
        try require(database.scopeOverview(state: state).precinctCount == expectedCounts[state],
                    "\(state) scope overview count differs in Swift")

        var stateRows = 0
        var stateNulls = 0
        for county in counties {
            try require(database.baseline(scope: "county|\(state)|\(county)") != nil,
                        "\(state) \(county) baseline is unreadable in Swift")
            let rows = database.countyRows(
                state: state,
                county: county,
                lon: 0,
                lat: 0,
                limit: 1_000
            )
            try require(!rows.isEmpty && rows.count < 1_000,
                        "\(state) \(county) rows are empty or truncated in Swift")
            let pins = PrecinctDB.makePins(rows)
            try require(pins.count == rows.count && pins.allSatisfy { !$0.rings.isEmpty },
                        "\(state) \(county) has a geometry Swift cannot decode")
            stateRows += rows.count
            decodedCandidateRows += rows.count

            for row in rows {
                guard let hit = database.precinct(unitID: row.id) else {
                    throw HarnessFailure(description: "Swift exact lookup failed for \(row.id)")
                }
                try require(hit.profile.state == state && hit.profile.borough == county,
                            "Swift exact lookup escaped \(state) \(county) for \(row.id)")
                if hit.profile.leanYear == nil {
                    stateNulls += 1
                    try require(
                        hit.profile.leanDemShare == nil
                            && hit.profile.prevDemShare == nil
                            && hit.profile.prevYear == nil
                            && hit.profile.leanLabel == nil
                            && hit.profile.leanShift == nil
                            && hit.profile.leanVotes == nil
                            && hit.profile.turnoutEst == nil
                            && !hit.profile.dataComplete,
                        "Swift synthesized political values for \(row.id)"
                    )
                    try require(database.electionSeries(unitID: row.id).isEmpty,
                                "Swift returned election rows for null profile \(row.id)")
                }
            }

            let regions = database.countyLeanRegions(state: state, county: county)
            try require(!regions.isEmpty, "\(state) \(county) lean regions are missing in Swift")
            let regionPins = PrecinctDB.makePins(regions)
            try require(regionPins.count == regions.count && regionPins.allSatisfy { !$0.rings.isEmpty },
                        "\(state) \(county) has a lean region Swift cannot decode")
            decodedRegionRows += regionPins.count
        }
        try require(stateRows == expectedCounts[state], "\(state) candidate row count differs in Swift")
        try require(stateNulls == expectedNullCounts[state], "\(state) political-null count differs in Swift")

        let facts = database.funFacts(state: state)
        try require(!facts.isEmpty, "\(state) By the Numbers facts are empty in Swift")
        for fact in facts {
            if let unitID = fact.unitID {
                try require(database.precinct(unitID: unitID)?.profile.state == state,
                            "\(state) fact winner escaped the state in Swift")
            }
            if let specification = fact.leaderboard {
                let leaders = database.topPrecincts(specification)
                try require(!leaders.isEmpty && leaders.allSatisfy { $0.state == state },
                            "\(state) leaderboard is empty or leaks another state in Swift")
            }
        }
        try require(!database.searchPrecincts(state: state, query: "").isEmpty,
                    "\(state) precinct-name search is empty in Swift")
    }

    let requiredProfiles = [
        ("41051-:-2806", "OR", false),
        ("41005-:-X000", "OR", true),
        ("08041-:-5122121800", "CO", false),
        ("08005-:-6276103288", "CO", true),
    ]
    for (unitID, state, shouldBeNull) in requiredProfiles {
        guard let hit = database.precinct(unitID: unitID) else {
            throw HarnessFailure(description: "required Swift profile is missing: \(unitID)")
        }
        try require(hit.profile.state == state && !hit.rings.isEmpty,
                    "required Swift profile differs: \(unitID)")
        try require((hit.profile.leanYear == nil) == shouldBeNull,
                    "required Swift profile has wrong election availability: \(unitID)")
        try require(database.baseline(scope: state) != nil,
                    "required Swift state baseline is missing: \(unitID)")
        try require(database.baseline(scope: "county|\(state)|\(hit.profile.borough)") != nil,
                    "required Swift county baseline is missing: \(unitID)")
    }

    var candidateSamples = 0
    var existingSamples = 0
    for sample in samples {
        guard let hit = database.lookup(lon: sample.longitude, lat: sample.latitude) else {
            throw HarnessFailure(description: "Swift representative lookup missed \(sample.state) \(sample.county)")
        }
        try require(hit.profile.state == sample.state && hit.profile.borough == sample.county,
                    "Swift representative lookup escaped \(sample.state) \(sample.county)")
        if sample.mode == "unit" {
            try require(hit.profile.unitID == sample.unitID,
                        "Swift representative lookup selected the wrong existing unit")
            existingSamples += 1
        } else {
            try require(sample.mode == "county", "unknown Swift sample mode")
            candidateSamples += 1
        }
        try require(!hit.rings.isEmpty, "Swift representative lookup returned no rings")
    }

    let midwayLongitude = -117.9863579
    let midwayLatitude = 33.7447024
    try require(database.lookup(lon: midwayLongitude, lat: midwayLatitude) == nil,
                "Swift strict lookup unexpectedly filled the Midway seam")
    try require(
        database.lookupForSearch(
            lon: midwayLongitude,
            lat: midwayLatitude,
            maxSnapMeters: 0.1
        ) == nil,
        "Swift search crossed the Midway seam below the permitted distance"
    )
    guard let midway = database.lookupForSearch(lon: midwayLongitude, lat: midwayLatitude) else {
        throw HarnessFailure(description: "Swift search did not bridge the Midway seam")
    }
    try require(midway.profile.state == "CA" && midway.profile.borough == "Orange",
                "Swift search bridged the Midway seam to the wrong county")

    let dmvOverview = database.scopeOverview(region: .dmvCore)
    try require(dmvOverview.precinctCount == 1_310, "Swift DMV scope count changed")
    try require(database.baseline(scope: "region|DMV") != nil, "Swift DMV baseline is unreadable")
    let dmvFacts = database.funFacts(region: .dmvCore)
    try require(!dmvFacts.isEmpty, "Swift DMV facts are empty")
    for fact in dmvFacts {
        if let unitID = fact.unitID, let profile = database.precinct(unitID: unitID)?.profile {
            try require(CoverageRegion.dmvCore.contains(profile),
                        "Swift DMV fact escaped the aggregate scope")
        }
    }

    return [
        "candidate_county_samples": candidateSamples,
        "candidate_geometry_rows_decoded": decodedCandidateRows,
        "candidate_political_null_profiles": 7,
        "candidate_region_rows_decoded": decodedRegionRows,
        "dmv_precinct_count": dmvOverview.precinctCount,
        "existing_state_samples": existingSamples,
        "midway_search_fallback": "PASS",
        "result": "PASS",
    ]
}

@main
private enum Phase3SwiftContractHarness {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw HarnessFailure(description: "usage: phase3-swift-contract <database> <samples.json>")
            }
            let result = try runHarness(
                databasePath: CommandLine.arguments[1],
                samplesPath: CommandLine.arguments[2]
            )
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            guard let output = String(data: data, encoding: .utf8) else {
                throw HarnessFailure(description: "could not encode Swift verification result")
            }
            print(output)
        } catch {
            FileHandle.standardError.write(Data("PHASE 3 SWIFT CONTRACT FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
