import CoreLocation
import Foundation
import SQLite3
import XCTest
@testable import PrecinctKit

final class PrecinctDBContractTests: XCTestCase {
    private let knownLocations: [(state: String, lat: Double, lon: Double)] = [
        ("CA", 34.0537, -118.2428),
        ("CO", 39.7390, -104.9900),
        ("MA", 42.3550, -71.0650),
        ("NY", 40.7580, -73.9850),
        ("OR", 45.5150, -122.6780),
        ("TX", 30.2747, -97.7404),
    ]

    func testBundledDatabaseResolvesEverySupportedStateAndRejectsInvalidCoordinates() {
        let db = PrecinctDB.shared
        XCTAssertTrue(db.isAvailable)

        for location in knownLocations {
            let hit = db.lookup(lon: location.lon, lat: location.lat)
            XCTAssertEqual(hit?.profile.state, location.state)
            XCTAssertFalse(hit?.rings.isEmpty ?? true)
            XCTAssertTrue(hit?.rings.flatMap { $0 }.allSatisfy {
                $0.latitude.isFinite && $0.longitude.isFinite
            } ?? false)
        }

        XCTAssertNil(db.lookup(lon: -72.5, lat: 40.0))
        XCTAssertNil(db.lookup(lon: .nan, lat: 40))
        XCTAssertNil(db.lookup(lon: -74, lat: .infinity))
    }

    func testSearchBridgesOnlyTinyPrecinctSeams() throws {
        let db = PrecinctDB.shared
        let midway = (lat: 33.7447024, lon: -117.9863579)

        XCTAssertNil(db.lookup(lon: midway.lon, lat: midway.lat),
                     "the regression coordinate must exercise the public-data seam")
        XCTAssertNil(db.lookupForSearch(lon: midway.lon, lat: midway.lat, maxSnapMeters: 0.1))
        let hit = try XCTUnwrap(db.lookupForSearch(lon: midway.lon, lat: midway.lat))
        XCTAssertEqual(hit.profile.state, "CA")
        XCTAssertEqual(hit.profile.borough, "Orange")

        let realCoverageEdges = [
            ("DMV north", lat: 39.35354691620166, lon: -77.16880099972411),
            ("CA west", lat: 40.438449348200834, lon: -124.40954716204412),
            ("NY north", lat: 45.015909915558744, lon: -74.826576),
            ("OR west", lat: 42.8402723, lon: -124.5530194),
            ("OR coast corner", lat: 43.3974036628, lon: -124.1901644990),
            ("CO southwest", lat: 37.3268599, lon: -109.0457985),
            ("CO north corner", lat: 41.0022035089, lon: -102.9048749282),
            ("TX south", lat: 25.837119084441248, lon: -97.39450199999999),
        ]
        for edge in realCoverageEdges {
            XCTAssertNil(db.lookup(lon: edge.lon, lat: edge.lat), "\(edge.0) must stay outside")
            XCTAssertNil(db.lookupForSearch(lon: edge.lon, lat: edge.lat),
                         "\(edge.0) is an outer coverage edge, not an internal precinct seam")
        }

        let legitimateHole = (lat: 38.13643764289524, lon: -120.45687093660658)
        XCTAssertNil(db.lookup(lon: legitimateHole.lon, lat: legitimateHole.lat))
        XCTAssertNil(db.lookupForSearch(lon: legitimateHole.lon, lat: legitimateHole.lat),
                     "a deliberate interior ring must not be filled by search snapping")

        XCTAssertNil(db.lookupForSearch(lon: realCoverageEdges[1].lon,
                                        lat: realCoverageEdges[1].lat,
                                        maxSnapMeters: 10_000),
                     "callers cannot expand the search fallback beyond its 10 meter contract")

        XCTAssertNil(db.lookupForSearch(lon: -72.5, lat: 40.0),
                     "search must not turn a genuinely uncovered location into a precinct")
    }

    func testFunFactsAndLeaderboardsResolveExactPrecincts() {
        let db = PrecinctDB.shared
        for state in ["CA", "CO", "MA", "NY", "OR", "TX"] {
            let facts = db.funFacts(state: state)
            XCTAssertFalse(facts.isEmpty, "No facts for \(state)")
            XCTAssertEqual(Set(facts.map(\.id)).count, facts.count, "Duplicate fact IDs for \(state)")

            for fact in facts {
                XCTAssertEqual(fact.lat == nil, fact.lon == nil, "Half-present coordinate for \(fact.id)")
                if fact.lat != nil {
                    XCTAssertNotNil(fact.unitID, "Coordinate without unit ID for \(fact.id)")
                }
                if let unitID = fact.unitID {
                    let profile = db.precinct(unitID: unitID)?.profile
                    XCTAssertEqual(profile?.unitID, unitID)
                    if fact.category == .politics {
                        XCTAssertNotNil(profile?.leanDemShare,
                                        "Political fact admitted an election-null precinct in \(state)")
                    }
                }
                if let spec = fact.leaderboard {
                    let rows = db.topPrecincts(spec)
                    XCTAssertFalse(rows.isEmpty, "Empty leaderboard for \(state) \(fact.id)")
                    XCTAssertEqual(rows.first?.id, fact.unitID, "Winner mismatch for \(state) \(fact.id)")
                    for row in rows {
                        let profile = db.precinct(unitID: row.id)?.profile
                        XCTAssertEqual(profile?.unitID, row.id)
                        if fact.category == .politics {
                            XCTAssertNotNil(profile?.leanDemShare,
                                            "Political leaderboard admitted an election-null precinct in \(state)")
                        }
                    }
                }
            }
        }
    }

    func testPoliticalNullProfilesKeepDemographicsWithoutPoliticalOutput() throws {
        let db = PrecinctDB.shared
        let unitIDs = [
            "41005-:-X000", "41027-:-XXXX", "41045-:-0019",
            "08005-:-6276103288", "08005-:-4276103350", "08005-:-6283603359",
            "08035-:-4303918103",
        ]

        for unitID in unitIDs {
            let profile = try XCTUnwrap(db.precinct(unitID: unitID)?.profile, unitID)
            XCTAssertNil(profile.leanDemShare, unitID)
            XCTAssertNil(profile.leanYear, unitID)
            XCTAssertNil(profile.leanVotes, unitID)
            XCTAssertEqual(profile.leanShort, "No election data", unitID)
            XCTAssertNotNil(profile.popTotal, unitID)
            XCTAssertFalse(profile.raceBreakdown.isEmpty, unitID)
        }
    }

    func testDMVFunFactsAndLeaderboardsUseTheAggregateScope() {
        let db = PrecinctDB.shared
        let facts = db.funFacts(region: .dmvCore)
        XCTAssertGreaterThan(facts.count, 10)
        XCTAssertEqual(Set(facts.map(\.category)), Set(FactCategory.allCases))

        for fact in facts {
            if let unitID = fact.unitID {
                XCTAssertTrue(CoverageRegion.dmvCore.contains(db.precinct(unitID: unitID)!.profile))
            }
            if let spec = fact.leaderboard {
                let rows = db.topPrecincts(spec)
                XCTAssertFalse(rows.isEmpty, "Empty DMV leaderboard for \(fact.id)")
                XCTAssertEqual(rows.first?.id, fact.unitID, "DMV winner mismatch for \(fact.id)")
                XCTAssertTrue(rows.allSatisfy {
                    guard let hit = db.precinct(unitID: $0.id) else { return false }
                    return CoverageRegion.dmvCore.contains(hit.profile)
                })
            }
        }
    }

    func testNYIncomeLeaderboardIncludesEveryTopCodedTieThenNext25() throws {
        try assertTopCodedIncomeLeaderboard(
            facts: PrecinctDB.shared.funFacts(state: "NY"),
            scopeSQL: "state = 'NY'",
            label: "NY"
        )
    }

    func testCountyIncomeLeaderboardIncludesEveryTopCodedTieThenNext25() throws {
        try assertTopCodedIncomeLeaderboard(
            facts: PrecinctDB.shared.funFacts(state: "NY", county: "Westchester"),
            scopeSQL: "state = 'NY' AND borough = 'Westchester'",
            label: "Westchester"
        )
    }

    func testDMVIncomeLeaderboardIncludesEveryTopCodedTieThenNext25() throws {
        let prefixes = CoverageRegion.dmvCore.jurisdictions.map { "unit_id LIKE '\($0.code)-%'" }
        try assertTopCodedIncomeLeaderboard(
            facts: PrecinctDB.shared.funFacts(region: .dmvCore),
            scopeSQL: "(\(prefixes.joined(separator: " OR ")))",
            label: "DMV"
        )
    }

    func testUncappedStateIncomeLeaderboardsUseGenericNoteAndMatchingWinner() throws {
        for state in ["OR", "DC"] {
            try assertUncappedIncomeLeaderboard(state: state, county: nil, label: state)
        }
    }

    func testUncappedCountyIncomeLeaderboardsUsePopulationTiebreakAndGenericNote() throws {
        for county in ["Concho", "Lynn", "Waller"] {
            try assertUncappedIncomeLeaderboard(state: "TX", county: county, label: county)
        }
    }

    func testSingleTopCodedPrecinctUsesSingularPresentation() throws {
        let scopes = [
            ("CA", "Monterey"), ("CA", "Santa Barbara"),
            ("NY", "Bronx"), ("NY", "Monroe"),
            ("TX", "Bexar"), ("TX", "Travis"),
            ("VA", "Loudoun"),
        ]
        for (state, county) in scopes {
            let fact = try XCTUnwrap(
                PrecinctDB.shared.funFacts(state: state, county: county).first { $0.id == "income" },
                "\(state) \(county)"
            )
            let spec = try XCTUnwrap(fact.leaderboard, "\(state) \(county)")
            XCTAssertEqual(fact.tieCount, 1, "\(state) \(county)")
            XCTAssertEqual(fact.tieCountLabel, "1 precinct", "\(state) \(county)")
            XCTAssertEqual(spec.unrankedTieCount, 1, "\(state) \(county)")
            XCTAssertEqual(spec.unrankedTieSummary(value: "$250k+"),
                           "1 precinct is tied at $250k+", "\(state) \(county)")
        }

        let ny = try XCTUnwrap(
            PrecinctDB.shared.funFacts(state: "NY").first { $0.id == "income" }?.leaderboard
        )
        XCTAssertEqual(ny.unrankedTieSummary(value: "$250k+"),
                       "166 precincts tie at $250k+")
    }

    func testPublicLimitsRejectUnboundedAndNonPositiveRequests() throws {
        let db = PrecinctDB.shared
        XCTAssertTrue(db.countyRows(state: "CA", county: "Los Angeles", lon: -118.24, lat: 34.05, limit: 0).isEmpty)
        XCTAssertTrue(db.countyRows(state: "CA", county: "Los Angeles", lon: -118.24, lat: 34.05, limit: -1).isEmpty)
        XCTAssertLessThanOrEqual(
            db.countyRows(state: "CA", county: "Los Angeles", lon: -118.24, lat: 34.05, limit: .max).count,
            1_000
        )
        XCTAssertTrue(db.searchPrecincts(state: "NY", query: "%", limit: -1).isEmpty)
        XCTAssertTrue(db.searchPrecincts(state: "NY", query: "%", limit: 100).isEmpty)
        XCTAssertLessThanOrEqual(db.searchPrecincts(state: "NY", query: "", limit: .max).count, 100)

        let fact = try XCTUnwrap(db.funFacts(state: "NY").first { $0.leaderboard != nil })
        let spec = try XCTUnwrap(fact.leaderboard)
        XCTAssertTrue(db.topPrecincts(spec, limit: -1).isEmpty)
        XCTAssertLessThanOrEqual(db.topPrecincts(spec, limit: .max).count, 100)
    }

    func testSharedConnectionSupportsConcurrentWidgetStyleReads() {
        let db = PrecinctDB.shared
        let lock = NSLock()
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let location = knownLocations[iteration % knownLocations.count]
            guard let hit = db.lookup(lon: location.lon, lat: location.lat) else {
                lock.withLock { failures.append("lookup \(iteration)") }
                return
            }
            let exact = db.precinct(unitID: hit.profile.unitID)
            let elections = db.electionSeries(unitID: hit.profile.unitID)
            if exact?.profile.unitID != hit.profile.unitID || elections.isEmpty {
                lock.withLock { failures.append("read \(iteration)") }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.prefix(10).joined(separator: ", "))
    }

    func testBundledArtifactIntegrityAndRelationalInvariants() throws {
        let url = try XCTUnwrap(
            Bundle(for: PrecinctDB.self).url(forResource: "nyc_precincts", withExtension: "sqlite")
        )
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK
        )
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }

        XCTAssertEqual(try textScalar(database, "PRAGMA integrity_check"), "ok")
        XCTAssertEqual(
            try textScalar(
                database,
                "SELECT group_concat(state, ',') FROM (SELECT DISTINCT state FROM precincts ORDER BY state)"
            ),
            "CA,CO,DC,MA,MD,NY,OR,TX,VA"
        )
        let precinctCount = try intScalar(database, "SELECT count(*) FROM precincts")
        XCTAssertEqual(precinctCount, 54_718)
        XCTAssertEqual(try intScalar(database, "SELECT count(*) FROM precinct_rtree"), precinctCount)
        XCTAssertEqual(try intScalar(database, "SELECT count(DISTINCT borough) FROM precincts WHERE state = 'OR'"), 36)
        XCTAssertEqual(try intScalar(database, "SELECT count(DISTINCT borough) FROM precincts WHERE state = 'CO'"), 64)
        XCTAssertEqual(
            try intScalar(database, "SELECT count(*) - count(DISTINCT unit_id) FROM precincts"),
            0
        )
        XCTAssertEqual(
            try intScalar(database, "SELECT count(*) FROM precincts WHERE unit_id IS NULL OR geometry_wkb IS NULL"),
            0
        )
        XCTAssertEqual(
            try intScalar(
                database,
                "SELECT count(*) FROM precinct_elections e LEFT JOIN precincts p USING(unit_id) WHERE p.unit_id IS NULL"
            ),
            0
        )
        XCTAssertEqual(
            try intScalar(
                database,
                "SELECT count(*) FROM precincts p LEFT JOIN precinct_rtree r ON r.id = p.rowid WHERE r.id IS NULL"
            ),
            0
        )
        XCTAssertEqual(
            try intScalar(
                database,
                "SELECT count(*) FROM (SELECT DISTINCT state, borough FROM precincts "
                    + "EXCEPT SELECT DISTINCT state, borough FROM county_lean_regions)"
            ),
            0
        )
    }

    func testBundledArtifactValuesStayWithinSupportedDomains() throws {
        let url = try XCTUnwrap(
            Bundle(for: PrecinctDB.self).url(forResource: "nyc_precincts", withExtension: "sqlite")
        )
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }

        let fractionColumns = [
            "lean_dem_share", "prev_dem_share", "pct_white", "pct_black", "pct_hispanic",
            "pct_asian", "pct_native", "pct_pacific", "pct_other", "pct_no_hs", "pct_hs",
            "pct_bachelors", "pct_graduate", "pct_ba_or_higher", "pct_renter", "pct_owner",
        ]
        let invalidFractions = fractionColumns
            .map { "\($0) NOT BETWEEN 0 AND 1" }
            .joined(separator: " OR ")
        XCTAssertEqual(
            try intScalar(database, "SELECT count(*) FROM precincts WHERE \(invalidFractions)"),
            0
        )
        XCTAssertEqual(
            try intScalar(
                database,
                "SELECT count(*) FROM precincts WHERE data_complete NOT IN (0, 1) "
                    + "OR pop_total < 0 OR vap_total < 0 OR cvap < 0 OR lean_votes < 0 "
                    + "OR turnout_est < 0 OR income_median < 0 OR pop_density < 0 "
                    + "OR avg_age < 0 OR avg_age > 120"
            ),
            0
        )
        XCTAssertEqual(
            try intScalar(
                database,
                "SELECT count(*) FROM precincts WHERE data_complete = 1 "
                    + "AND (lean_dem_share IS NULL OR pop_total IS NULL OR pop_total <= 0)"
            ),
            0
        )
    }

    func testEveryBundledGeometryDecodesWithTheShippingSwiftParser() throws {
        let url = try XCTUnwrap(
            Bundle(for: PrecinctDB.self).url(forResource: "nyc_precincts", withExtension: "sqlite")
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }

        var totalChecked = 0
        var failures: [String] = []
        for table in ["precincts", "county_lean_regions"] {
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(
                handle,
                "SELECT rowid, geometry_wkb FROM \(table)",
                -1,
                &statement,
                nil
            )
            XCTAssertEqual(prepareResult, SQLITE_OK, table)
            guard prepareResult == SQLITE_OK else { continue }

            var tableChecked = 0
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                tableChecked += 1
                let rowID = sqlite3_column_int64(statement, 0)
                if let bytes = sqlite3_column_blob(statement, 1) {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                    let rings = WKBGeometry.exteriorRings(data)
                    if rings.isEmpty || !rings.joined().allSatisfy({
                        $0.latitude.isFinite && $0.longitude.isFinite
                    }) {
                        if failures.count < 10 {
                            failures.append("\(table) row \(rowID): rejected or non-finite geometry")
                        }
                    }
                } else if failures.count < 10 {
                    failures.append("\(table) row \(rowID): missing geometry")
                }
                stepResult = sqlite3_step(statement)
            }
            XCTAssertEqual(stepResult, SQLITE_DONE, table)
            XCTAssertEqual(Int64(tableChecked), try intScalar(handle, "SELECT count(*) FROM \(table)"), table)
            totalChecked += tableChecked
            sqlite3_finalize(statement)
        }

        XCTAssertGreaterThan(totalChecked, 0)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
    }

    func testMissingCorruptAndWrongSchemaDatabasesFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("precinct-db-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.sqlite")
        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a sqlite database".utf8).write(to: corrupt)

        let empty = directory.appendingPathComponent("empty.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(empty.path, &handle), SQLITE_OK)
        sqlite3_close(handle)

        let wrongSchema = directory.appendingPathComponent("wrong-schema.sqlite")
        handle = nil
        XCTAssertEqual(sqlite3_open(wrongSchema.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE unrelated(value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        // This database has every required table and column except one field consumed by
        // baseline(scope:). It protects against partial schema checks that fail later as nil data.
        let missingBaselineColumn = directory.appendingPathComponent("missing-baseline-column.sqlite")
        handle = nil
        XCTAssertEqual(sqlite3_open(missingBaselineColumn.path, &handle), SQLITE_OK)
        let sourceURL = try XCTUnwrap(
            Bundle(for: PrecinctDB.self).url(forResource: "nyc_precincts", withExtension: "sqlite")
        )
        let escapedSourcePath = sourceURL.path.replacingOccurrences(of: "'", with: "''")
        let nearlyCorrectSchema = """
            ATTACH DATABASE '\(escapedSourcePath)' AS source;
            CREATE TABLE precincts AS SELECT * FROM source.precincts WHERE 0;
            CREATE TABLE precinct_rtree AS SELECT * FROM source.precinct_rtree WHERE 0;
            CREATE TABLE precinct_elections AS SELECT * FROM source.precinct_elections WHERE 0;
            CREATE TABLE county_lean_regions AS SELECT * FROM source.county_lean_regions WHERE 0;
            CREATE TABLE baselines AS
                SELECT scope, pct_white, pct_hispanic, pct_asian, pct_ba_or_higher,
                       income_median, pct_renter, avg_age, pres24_dem_share
                FROM source.baselines WHERE 0;
            DETACH DATABASE source;
            """
        XCTAssertEqual(sqlite3_exec(handle, nearlyCorrectSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        for url in [missing, corrupt, empty, wrongSchema, missingBaselineColumn] {
            let db = PrecinctDB(databaseURL: url)
            XCTAssertFalse(db.isAvailable, "Accepted invalid database \(url.lastPathComponent)")
            XCTAssertNil(db.lookup(lon: -74, lat: 40.7))
            XCTAssertTrue(db.counties(state: "NY").isEmpty)
        }
    }

    func testLookupUsesDeterministicOverlapPolicy() {
        let db = PrecinctDB.shared

        let nestedRealPrecinct = db.lookup(lon: -119.18990239702686, lat: 35.366799455276535)
        XCTAssertEqual(nestedRealPrecinct?.profile.unitID, "06029-:-060297041915")

        let nestedGhostSliver = db.lookup(lon: -121.6779830204748, lat: 37.91775349463404)
        XCTAssertNotEqual(nestedGhostSliver?.profile.unitID, "06013-:-06013MARC802")
        XCTAssertEqual(nestedGhostSliver?.profile.dataComplete, true)
    }

    private func intScalar(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW, sql)
        return sqlite3_column_int64(statement, 0)
    }

    private func textScalar(_ database: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW, sql)
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func assertTopCodedIncomeLeaderboard(
        facts: [FunFact],
        scopeSQL: String,
        label: String
    ) throws {
        let db = PrecinctDB.shared
        let fact = try XCTUnwrap(facts.first { $0.id == "income" }, label)
        let spec = try XCTUnwrap(fact.leaderboard, label)
        let tieCount = try XCTUnwrap(fact.tieCount, label)
        XCTAssertEqual(spec.unrankedTieCount, tieCount, label)
        XCTAssertEqual(spec.unrankedTieValue, 250001, label)

        let rows = db.topPrecincts(spec)
        let tied = Array(rows.prefix(tieCount))
        let ranked = Array(rows.dropFirst(tieCount))
        XCTAssertEqual(tied.count, tieCount, label)
        XCTAssertEqual(tied.map(\.value), Array(repeating: 250001, count: tieCount), label)
        XCTAssertEqual(tied.map(\.id), tied.map(\.id).sorted(), "\(label) tied order")
        XCTAssertEqual(ranked.count, 25, label)
        XCTAssertTrue(ranked.allSatisfy { $0.value < 250001 }, label)

        let actualPairs = rows.map { ($0.id, Int($0.value)) }
        let expectedPairs = try incomeLeaderboardRows(scopeSQL: scopeSQL)
        XCTAssertEqual(actualPairs.map(\.0), expectedPairs.map(\.0), "\(label) ids")
        XCTAssertEqual(actualPairs.map(\.1), expectedPairs.map(\.1), "\(label) values")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "\(label) duplicate ids")
        XCTAssertEqual(db.topPrecincts(spec, limit: 1).count, tieCount + 1, "\(label) tie completeness")
        for row in rows {
            let profile = try XCTUnwrap(db.precinct(unitID: row.id)?.profile, row.id)
            XCTAssertEqual(profile.unitID, row.id)
            XCTAssertEqual(profile.incomeMedian, Int(row.value), row.id)
        }
    }

    private func assertUncappedIncomeLeaderboard(
        state: String,
        county: String?,
        label: String
    ) throws {
        let db = PrecinctDB.shared
        let fact = try XCTUnwrap(
            db.funFacts(state: state, county: county).first { $0.id == "income" }, label
        )
        let spec = try XCTUnwrap(fact.leaderboard, label)
        let rows = db.topPrecincts(spec)
        XCTAssertNil(fact.tieCount, label)
        XCTAssertNil(spec.unrankedTieCount, label)
        XCTAssertNil(spec.unrankedTieValue, label)
        XCTAssertEqual(spec.note, "The top precincts here, ranked.", label)
        XCTAssertEqual(rows.first?.id, fact.unitID, label)
        XCTAssertEqual(rows.first?.value, Double(db.precinct(unitID: fact.unitID!)!.profile.incomeMedian!), label)
        XCTAssertTrue(rows.allSatisfy { $0.value < 250001 }, label)
    }

    private func incomeLeaderboardRows(scopeSQL: String) throws -> [(String, Int)] {
        let url = try XCTUnwrap(
            Bundle(for: PrecinctDB.self).url(forResource: "nyc_precincts", withExtension: "sqlite")
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        let sql = """
            SELECT unit_id, income_median FROM precincts
            WHERE \(scopeSQL) AND pop_total >= 500 AND income_median = 250001
            ORDER BY unit_id ASC;
            """ + """
            SELECT unit_id, income_median FROM precincts
            WHERE \(scopeSQL) AND pop_total >= 500 AND income_median < 250001
            ORDER BY income_median DESC, pop_total DESC, unit_id ASC LIMIT 25
            """
        var output: [(String, Int)] = []
        for statementSQL in sql.split(separator: ";") {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, String(statementSQL), -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                output.append((id, Int(sqlite3_column_int64(statement, 1))))
            }
        }
        return output
    }
}
