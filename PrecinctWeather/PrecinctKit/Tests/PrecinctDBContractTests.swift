import CoreLocation
import Foundation
import SQLite3
import XCTest
@testable import PrecinctKit

final class PrecinctDBContractTests: XCTestCase {
    private let knownLocations: [(state: String, lat: Double, lon: Double)] = [
        ("CA", 34.0537, -118.2428),
        ("MA", 42.3550, -71.0650),
        ("NY", 40.7580, -73.9850),
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

    func testFunFactsAndLeaderboardsResolveExactPrecincts() {
        let db = PrecinctDB.shared
        for state in ["CA", "MA", "NY", "TX"] {
            let facts = db.funFacts(state: state)
            XCTAssertFalse(facts.isEmpty, "No facts for \(state)")
            XCTAssertEqual(Set(facts.map(\.id)).count, facts.count, "Duplicate fact IDs for \(state)")

            for fact in facts {
                XCTAssertEqual(fact.lat == nil, fact.lon == nil, "Half-present coordinate for \(fact.id)")
                if fact.lat != nil {
                    XCTAssertNotNil(fact.unitID, "Coordinate without unit ID for \(fact.id)")
                }
                if let unitID = fact.unitID {
                    XCTAssertEqual(db.precinct(unitID: unitID)?.profile.unitID, unitID)
                }
                if let spec = fact.leaderboard {
                    let rows = db.topPrecincts(spec)
                    XCTAssertFalse(rows.isEmpty, "Empty leaderboard for \(state) \(fact.id)")
                    XCTAssertEqual(rows.first?.id, fact.unitID, "Winner mismatch for \(state) \(fact.id)")
                    for row in rows {
                        XCTAssertEqual(db.precinct(unitID: row.id)?.profile.unitID, row.id)
                    }
                }
            }
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
            "CA,DC,MA,MD,NY,TX,VA"
        )
        let precinctCount = try intScalar(database, "SELECT count(*) FROM precincts")
        XCTAssertGreaterThan(precinctCount, 0)
        XCTAssertEqual(try intScalar(database, "SELECT count(*) FROM precinct_rtree"), precinctCount)
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
}
