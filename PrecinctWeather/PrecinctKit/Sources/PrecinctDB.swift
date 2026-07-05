import Foundation
import CoreLocation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A precinct's polygon + lean, for drawing tinted overlays on the map.
public struct PrecinctPin: Identifiable, Sendable {
    public let id: String          // unit_id
    public let demShare: Double?   // 2024 president two-party Dem share -> color
    public let rings: [[CLLocationCoordinate2D]]
}

/// Read-only access to the bundled nyc_precincts.sqlite. Resolves a coordinate to
/// a precinct (R-tree bbox prefilter + exact point-in-polygon) and serves the
/// election time series, baselines, and nearby polygons for the map explorer.
public final class PrecinctDB {
    public static let shared = PrecinctDB()

    private var db: OpaquePointer?

    private init() {
        guard let url = Bundle(for: PrecinctDB.self)
            .url(forResource: "nyc_precincts", withExtension: "sqlite") else {
            assertionFailure("nyc_precincts.sqlite missing from PrecinctKit bundle")
            return
        }
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
    }

    deinit { if let db { sqlite3_close(db) } }

    /// False if the bundled database failed to open (lets the UI show a distinct error).
    public var isAvailable: Bool { db != nil }

    // MARK: Coordinate -> precinct

    /// Returns the matched precinct AND its already-decoded exterior rings. The WKB is decoded
    /// once here (it's read for the point-in-polygon test anyway), so callers reuse it for drawing
    /// and the camera bounding box instead of re-querying + re-decoding the same row.
    public func lookup(lon: Double, lat: Double)
        -> (profile: PrecinctProfile, rings: [[CLLocationCoordinate2D]])? {
        for id in candidateIDs(lon: lon, lat: lat) {
            if let (profile, wkb) = row(id: id),
               WKBGeometry.contains(wkb, lon: lon, lat: lat) {
                return (profile, WKBGeometry.exteriorRings(wkb))
            }
        }
        return nil
    }

    private func candidateIDs(lon: Double, lat: Double) -> [Int32] {
        let sql = """
            SELECT id FROM precinct_rtree
            WHERE ? BETWEEN min_lon AND max_lon AND ? BETWEEN min_lat AND max_lat
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, lon)
        sqlite3_bind_double(stmt, 2, lat)
        var ids: [Int32] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int(stmt, 0)) }
        return ids
    }

    // MARK: Geometry / map

    public func exteriorRings(unitID: String) -> [[CLLocationCoordinate2D]] {
        let sql = "SELECT geometry_wkb FROM precincts WHERE unit_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, unitID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let data = blob(stmt, 0) else { return [] }
        return WKBGeometry.exteriorRings(data)
    }

    /// Every precinct in one county/borough as raw rows (DB read only — fast, no WKB decode).
    /// Decode the blobs to rings OFF the main thread via `decodeRings`, then build `PrecinctPin`s,
    /// so tinting the surrounding county never stalls selection/expand. Capped so the biggest
    /// counties (2k+ precincts) can't stall the map; when capped, the nearest precincts to
    /// (lon,lat) win so the tint is a contiguous blob, not scattered.
    public func countyRows(state: String, county: String, lon: Double, lat: Double,
                           limit: Int = 1000) -> [(id: String, demShare: Double?, wkb: Data)] {
        let sql = """
            SELECT unit_id, lean_dem_share, geometry_wkb
            FROM precincts
            WHERE state = ? AND borough = ? AND geometry_wkb IS NOT NULL
            ORDER BY ((min_lon + max_lon) / 2 - ?) * ((min_lon + max_lon) / 2 - ?)
                   + ((min_lat + max_lat) / 2 - ?) * ((min_lat + max_lat) / 2 - ?)
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, county, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, lon); sqlite3_bind_double(stmt, 4, lon)
        sqlite3_bind_double(stmt, 5, lat); sqlite3_bind_double(stmt, 6, lat)
        sqlite3_bind_int(stmt, 7, Int32(limit))
        var out: [(id: String, demShare: Double?, wkb: Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uid = text(stmt, 0), let data = blob(stmt, 2) else { continue }
            out.append((uid, dbl(stmt, 1), data))
        }
        return out
    }

    /// Decode raw county rows (from `countyRows`) into drawable pins. Pure CPU (no DB handle),
    /// so it is safe to call off the main thread — keeps the county-tint decode off the UI thread.
    public static func makePins(_ rows: [(id: String, demShare: Double?, wkb: Data)]) -> [PrecinctPin] {
        rows.map { PrecinctPin(id: $0.id, demShare: $0.demShare, rings: WKBGeometry.exteriorRings($0.wkb)) }
    }

    /// A county dissolved into ≈5 lean REGIONS (one per Solid Rep…Solid Dem bucket) for the
    /// always-on county tint — ~5 polygons instead of thousands, so big counties (LA ~3,000
    /// precincts) stay smooth at every zoom. Built offline by add_lean_regions.py.
    /// Same row shape as `countyRows`, so `makePins` decodes it unchanged.
    public func countyLeanRegions(state: String, county: String) -> [(id: String, demShare: Double?, wkb: Data)] {
        let sql = """
            SELECT lean_label, dem_share, geometry_wkb
            FROM county_lean_regions
            WHERE state = ? AND borough = ? AND geometry_wkb IS NOT NULL
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, county, -1, SQLITE_TRANSIENT)
        var out: [(id: String, demShare: Double?, wkb: Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let label = text(stmt, 0), let data = blob(stmt, 2) else { continue }
            out.append(("region:\(label)", dbl(stmt, 1), data))   // id never matches a precinct unit_id
        }
        return out
    }

    // MARK: Election time series + baselines

    public func electionSeries(unitID: String) -> [ElectionResult] {
        let sql = """
            SELECT office, year, dem, rep, other, dem_share
            FROM precinct_elections WHERE unit_id = ? ORDER BY office, year
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, unitID, -1, SQLITE_TRANSIENT)
        var out: [ElectionResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ElectionResult(
                office: text(stmt, 0) ?? "", year: Int(sqlite3_column_int(stmt, 1)),
                dem: int(stmt, 2), rep: int(stmt, 3), other: int(stmt, 4), demShare: dbl(stmt, 5)))
        }
        return out
    }

    public func baseline(scope: String) -> Baseline? {
        let sql = """
            SELECT scope, pct_white, pct_black, pct_hispanic, pct_asian,
                   pct_ba_or_higher, income_median, pct_renter, avg_age, pres24_dem_share
            FROM baselines WHERE scope = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, scope, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Baseline(scope: text(stmt, 0) ?? scope,
                        pctWhite: dbl(stmt, 1), pctBlack: dbl(stmt, 2),
                        pctHispanic: dbl(stmt, 3), pctAsian: dbl(stmt, 4),
                        pctBachelorsOrHigher: dbl(stmt, 5), incomeMedian: int(stmt, 6),
                        pctRenter: dbl(stmt, 7), avgAge: dbl(stmt, 8),
                        leanDemShare: dbl(stmt, 9))
    }

    // MARK: Fun facts (dataset superlatives)

    /// Distinct counties/boroughs within a state, for the fun-facts scope filter.
    public func counties(state: String) -> [String] {
        let sql = "SELECT DISTINCT borough FROM precincts WHERE state = ? AND borough IS NOT NULL AND borough != '' ORDER BY borough"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let c = text(stmt, 0) { out.append(c) } }
        return out
    }

    /// Scope-level aggregates (counts, totals, true median income, lean distribution)
    /// shown at the top of the "By the Numbers" page.
    public func scopeOverview(state: String, county: String? = nil) -> ScopeOverview {
        let scope = county == nil ? "state = ?" : "state = ? AND borough = ?"
        let scopeBinds = county.map { [state, $0] } ?? [state]

        // One-shot scalar query helper.
        func scalar(_ sql: String, _ binds: [String] = []) -> Double? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindTexts(stmt, binds)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return dbl(stmt, 0)
        }

        let precinctCount = Int(scalar("SELECT COUNT(*) FROM precincts WHERE \(scope)", scopeBinds) ?? 0)

        let popSum = scalar("SELECT SUM(pop_total) FROM precincts WHERE \(scope) AND pop_total IS NOT NULL", scopeBinds)
        let totalPopulation = (popSum ?? 0) > 0 ? Int(popSum!) : nil

        let avgDemShare = scalar("SELECT AVG(lean_dem_share) FROM precincts WHERE \(scope) AND lean_votes >= 100", scopeBinds)

        // True median income: count non-null rows, then take the middle one.
        let n = Int(scalar("SELECT COUNT(*) FROM precincts WHERE \(scope) AND income_median IS NOT NULL", scopeBinds) ?? 0)
        let medianIncome: Int? = n == 0 ? nil : scalar("""
            SELECT income_median FROM precincts
            WHERE \(scope) AND income_median IS NOT NULL
            ORDER BY income_median LIMIT 1 OFFSET \(n / 2)
            """, scopeBinds).map { Int($0) }

        // Lean distribution counts, emitted in a fixed left→right order.
        var counts: [String: Int] = [:]
        let bucketSQL = """
            SELECT lean_label, COUNT(*) FROM precincts
            WHERE \(scope) AND lean_label IS NOT NULL GROUP BY lean_label
            """
        var bstmt: OpaquePointer?
        if sqlite3_prepare_v2(db, bucketSQL, -1, &bstmt, nil) == SQLITE_OK {
            bindTexts(bstmt, scopeBinds)
            while sqlite3_step(bstmt) == SQLITE_ROW {
                if let label = text(bstmt, 0) { counts[label] = Int(sqlite3_column_int(bstmt, 1)) }
            }
        }
        sqlite3_finalize(bstmt)
        let leanOrder = ["Solid Rep", "Lean Rep", "Even", "Lean Dem", "Solid Dem"]
        let leanBuckets = leanOrder.compactMap { label -> LeanBucket? in
            guard let c = counts[label], c > 0 else { return nil }
            return LeanBucket(label: label, count: c)
        }

        return ScopeOverview(precinctCount: precinctCount, totalPopulation: totalPopulation,
                             avgDemShare: avgDemShare, medianIncome: medianIncome,
                             leanBuckets: leanBuckets)
    }

    public func funFacts(state: String, county: String? = nil) -> [FunFact] {
        var facts: [FunFact] = []
        let scope = county == nil ? "state = ?" : "state = ? AND borough = ?"
        let scopeBinds = county.map { [state, $0] } ?? [state]

        // With a county filter the county is already in the header, so showing "County, ST" on
        // every card is redundant — show the precinct id instead. Statewide, the county is the
        // useful locator. (Precinct names are SOS ids: "AD 65 ED 21" in NY, a number in CA.)
        func placeStr(_ boro: String, _ st: String, _ pname: String) -> String {
            if county != nil {
                if pname.isEmpty { return "\(countyDisplay(boro)), \(st)" }
                // MA names already read "Chatham Town Precinct 1"; don't double the word.
                return pname.localizedCaseInsensitiveContains("precinct") ? pname : "Precinct \(pname)"
            }
            return pname.isEmpty ? "\(countyDisplay(boro)), \(st)" : "\(countyDisplay(boro)), \(st) (\(pname))"
        }

        // A cap/ceiling tie: the column shown per row, the SQL band that defines "shares the
        // displayed value" (e.g. income_median = 250001, or ROUND(pct_renter*100) = 100), the
        // value kind for formatting, and a one-line honest reason for the leaderboard header.
        typealias Tie = (col: String, band: String, kind: LeaderboardSpec.ValueKind, note: String)

        // For cap/ceiling facts: how big the tie at the displayed value is (e.g. how many precincts
        // sit at the $250k income cap or round to 100% renter), shown as a "N tied" chip. Only surface
        // a real crowd (3+); 1–2 isn't one. Every fact still gets a full "see all" list regardless.
        func tieCnt(_ tie: Tie?, filter: String) -> Int? {
            guard let tie else { return nil }
            let sql = "SELECT COUNT(*) FROM precincts WHERE \(scope)\(filter.isEmpty ? "" : " AND \(filter)") AND \(tie.band)"
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(s) }
            bindTexts(s, scopeBinds)
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            let c = Int(sqlite3_column_int(s, 0))
            return c >= 3 ? c : nil
        }

        // Best precinct by a single column. Ties broken by population (then unit_id) so the
        // surfaced winner is deterministic and meaningful, not insertion-order.
        func top(_ id: String, _ icon: String, _ title: String, column: String,
                 category: FactCategory, kind: FactKind,
                 ascending: Bool, filter: String, displayKind: LeaderboardSpec.ValueKind,
                 pairKey: String? = nil, subtitle: String? = nil, tie: Tie? = nil,
                 fmt: (Double) -> String) {
            let sql = """
                SELECT borough, state, precinct_name, \(column),
                       (min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0
                FROM precincts
                WHERE \(scope) AND \(column) IS NOT NULL\(filter.isEmpty ? "" : " AND \(filter)")
                ORDER BY \(column) \(ascending ? "ASC" : "DESC"), pop_total DESC, unit_id ASC LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindTexts(stmt, scopeBinds)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            let place = placeStr(text(stmt, 0) ?? "", text(stmt, 1) ?? "", text(stmt, 2) ?? "")
            let lb = LeaderboardSpec(factID: id, title: title,
                                     note: tie?.note ?? "The top precincts here, ranked.",
                                     state: state, county: county,
                                     valueColumn: column, baseFilter: filter,
                                     ascending: ascending, displayKind: displayKind)
            facts.append(FunFact(id: id, icon: icon, title: title,
                                 value: fmt(sqlite3_column_double(stmt, 3)), place: place,
                                 lat: sqlite3_column_double(stmt, 5), lon: sqlite3_column_double(stmt, 4),
                                 category: category, kind: kind, pairKey: pairKey, subtitle: subtitle,
                                 tieCount: tieCnt(tie, filter: filter), leaderboard: lb))
        }

        // Best precinct by an arbitrary SQL expression, with a possibly-different display value.
        func topComputed(_ id: String, _ icon: String, _ title: String,
                         category: FactCategory, kind: FactKind,
                         orderExpr: String, displayExpr: String, ascending: Bool,
                         filter: String, displayKind: LeaderboardSpec.ValueKind,
                         pairKey: String? = nil, subtitle: String? = nil, tie: Tie? = nil,
                         fmt: (Double) -> String) {
            let sql = """
                SELECT borough, state, precinct_name, (\(displayExpr)) AS v,
                       (min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0
                FROM precincts
                WHERE \(scope) AND (\(displayExpr)) IS NOT NULL\(filter.isEmpty ? "" : " AND \(filter)")
                ORDER BY (\(orderExpr)) \(ascending ? "ASC" : "DESC"), pop_total DESC, unit_id ASC LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindTexts(stmt, scopeBinds)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            let place = placeStr(text(stmt, 0) ?? "", text(stmt, 1) ?? "", text(stmt, 2) ?? "")
            let lb = LeaderboardSpec(factID: id, title: title,
                                     note: tie?.note ?? "The top precincts here, ranked.",
                                     state: state, county: county,
                                     valueColumn: displayExpr, orderExpr: orderExpr, baseFilter: filter,
                                     ascending: ascending, displayKind: displayKind)
            facts.append(FunFact(id: id, icon: icon, title: title,
                                 value: fmt(sqlite3_column_double(stmt, 3)), place: place,
                                 lat: sqlite3_column_double(stmt, 5), lon: sqlite3_column_double(stmt, 4),
                                 category: category, kind: kind, pairKey: pairKey, subtitle: subtitle,
                                 tieCount: tieCnt(tie, filter: filter), leaderboard: lb))
        }

        // Senate-vs-President crossover (NY/MA only; CA has no senate data).
        func topCrossover() {
            // Same scope binds, but referencing the `p` (precincts) alias used in the joins.
            let pScope = county == nil ? "p.state = ?" : "p.state = ? AND p.borough = ?"

            // Latest year where senate data exists for this scope.
            let yearSQL = """
                SELECT MAX(e.year) FROM precinct_elections e
                JOIN precincts p ON p.unit_id = e.unit_id
                WHERE e.office = 'senate' AND \(pScope)
                """
            var ystmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, yearSQL, -1, &ystmt, nil) == SQLITE_OK else { return }
            bindTexts(ystmt, scopeBinds)
            let haveYear = sqlite3_step(ystmt) == SQLITE_ROW
            let year = haveYear ? int(ystmt, 0) : nil
            sqlite3_finalize(ystmt)
            guard let y = year else { return }

            let sql = """
                SELECT p.borough, p.state, p.precinct_name, (se.dem_share - ps.dem_share) AS v,
                       (p.min_lon + p.max_lon) / 2.0, (p.min_lat + p.max_lat) / 2.0
                FROM precincts p
                JOIN precinct_elections ps ON ps.unit_id = p.unit_id AND ps.office = 'president' AND ps.year = \(y)
                JOIN precinct_elections se ON se.unit_id = p.unit_id AND se.office = 'senate'    AND se.year = \(y)
                WHERE \(pScope) AND ps.dem + ps.rep >= 200 AND se.dem + se.rep >= 200
                  AND ps.dem_share BETWEEN 0.15 AND 0.85 AND se.dem_share BETWEEN 0.15 AND 0.85
                ORDER BY ABS(se.dem_share - ps.dem_share) DESC LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindTexts(stmt, scopeBinds)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            let v = sqlite3_column_double(stmt, 3)
            // Short value so it fits the trailing column; the subtitle carries the Senate-vs-President
            // framing. v = senate minus president Dem share, i.e. how much more one office leaned.
            let value = v >= 0 ? "D+\(Int((v * 100).rounded())) split"
                               : "R+\(Int((abs(v) * 100).rounded())) split"
            let place = placeStr(text(stmt, 0) ?? "", text(stmt, 1) ?? "", text(stmt, 2) ?? "")
            facts.append(FunFact(id: "crossover", icon: "arrow.left.arrow.right",
                                 title: "Ticket-splitters", value: value, place: place,
                                 lat: sqlite3_column_double(stmt, 5), lon: sqlite3_column_double(stmt, 4),
                                 category: .politics, kind: .insight,
                                 subtitle: "Split most between Senate and President"))
        }

        let votes = "lean_votes >= 100"
        // Census small-area medians/shares are mostly noise below ~500 people (large MOEs, group
        // quarters, mis-joined slivers), so superlatives require a real-size precinct.
        let pop = "pop_total >= 500"
        let popStrict = "pop_total >= 500"
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        // ACS top-codes household income at "$250,000+", stored as the sentinel 250001.
        let money: (Double) -> String = { $0 >= 250001 ? "$250k+" : "$\(Int($0).formatted())" }
        // Format a 0...1 Dem share as a signed two-party margin label.
        let leanMargin: (Double) -> String = {
            let m = Int(((($0 - 0.5) * 200)).rounded())
            if m > 0 { return "D+\(m)" }
            if m < 0 { return "R+\(-m)" }
            return "Even"
        }

        // MARK: Politics
        top("dem", "building.columns", "Most Democratic", column: "lean_dem_share",
            category: .politics, kind: .rangeHigh, ascending: false, filter: votes,
            displayKind: .lean, pairKey: "lean", fmt: leanMargin)
        top("rep", "building.columns", "Most Republican", column: "lean_dem_share",
            category: .politics, kind: .rangeLow, ascending: true, filter: votes,
            displayKind: .lean, pairKey: "lean", fmt: leanMargin)
        top("shiftD", "arrow.left.arrow.right", "Biggest Dem shift", column: "lean_shift",
            category: .politics, kind: .rangeHigh, ascending: false, filter: votes,
            displayKind: .shiftPts, pairKey: "shift") { "D+\(Int(($0 * 100).rounded()))" }
        top("shiftR", "arrow.left.arrow.right", "Biggest GOP shift", column: "lean_shift",
            category: .politics, kind: .rangeLow, ascending: true, filter: votes,
            displayKind: .shiftPts, pairKey: "shift") { "R+\(Int((abs($0) * 100).rounded()))" }
        topComputed("competitive", "equal.circle", "Most competitive",
                    category: .politics, kind: .insight,
                    orderExpr: "ABS(lean_dem_share - 0.5)", displayExpr: "lean_dem_share",
                    ascending: true, filter: votes, displayKind: .lean,
                    subtitle: nil, fmt: leanMargin)
        topCrossover()

        // MARK: Race & demographics
        top("white", "person.3", "Most White", column: "pct_white",
            category: .race, kind: .leaderboard, ascending: false, filter: pop, displayKind: .pct, fmt: pct)
        top("black", "person.3", "Most Black", column: "pct_black",
            category: .race, kind: .leaderboard, ascending: false, filter: pop, displayKind: .pct, fmt: pct)
        top("hispanic", "person.3", "Most Hispanic", column: "pct_hispanic",
            category: .race, kind: .leaderboard, ascending: false, filter: pop, displayKind: .pct, fmt: pct)
        top("asian", "person.3", "Most Asian", column: "pct_asian",
            category: .race, kind: .leaderboard, ascending: false, filter: pop, displayKind: .pct, fmt: pct)
        // No "Most diverse" fact: race shares overlap with Hispanic ethnicity in Census data
        // (Hispanics often also mark "Some Other Race"), so a Herfindahl diversity index would be
        // distorted. A correct version needs non-Hispanic-by-race data (a pipeline change).

        // MARK: Wealth & housing
        topComputed("income", "dollarsign.circle", "Highest income",
                    category: .wealth, kind: .rangeHigh,
                    orderExpr: "income_median", displayExpr: "income_median",
                    ascending: false, filter: pop, displayKind: .money, pairKey: "income",
                    tie: ("income_median", "income_median = 250001", .money,
                          "The Census caps reported income at $250k, so the top precincts tie at the ceiling.")) { money($0) }
        top("incomeLow", "dollarsign.circle", "Lowest income", column: "income_median",
            category: .wealth, kind: .rangeLow, ascending: true,
            filter: "\(popStrict) AND income_median >= 10000", displayKind: .money, pairKey: "income") { money($0) }
        top("renter", "house", "Most renters", column: "pct_renter",
            category: .wealth, kind: .insight, ascending: false, filter: pop,
            displayKind: .pct, pairKey: "tenure",
            subtitle: nil,
            tie: ("pct_renter", "ROUND(pct_renter * 100) = 100", .pct,
                  "The most renter-occupied precincts in this area."),
            fmt: pct)
        top("owner", "house", "Most homeowners", column: "pct_owner",
            category: .wealth, kind: .insight, ascending: false, filter: pop,
            displayKind: .pct, pairKey: "tenure",
            subtitle: nil,
            tie: ("pct_owner", "ROUND(pct_owner * 100) = 100", .pct,
                  "The most owner-occupied precincts in this area."),
            fmt: pct)

        // MARK: Education
        top("edu", "graduationcap", "Most college-educated", column: "pct_ba_or_higher",
            category: .education, kind: .rangeHigh, ascending: false, filter: pop,
            displayKind: .pct, pairKey: "edu", fmt: pct)
        top("eduLow", "graduationcap", "Least college-educated", column: "pct_ba_or_higher",
            category: .education, kind: .rangeLow, ascending: true, filter: popStrict,
            displayKind: .pct, pairKey: "edu", fmt: pct)

        // MARK: Population & age
        top("dense", "building.2", "Densest", column: "pop_density",
            category: .population, kind: .leaderboard, ascending: false, filter: pop, displayKind: .density) {
            "\(Int($0).formatted())/mi²"
        }
        // Turnout intentionally has NO superlative: it's votes / a Census 5-year CVAP estimate on
        // mismatched boundaries, so it routinely exceeds 100% and the extremes are mostly estimate
        // noise at both ends, so we don't rank it at all.
        top("age", "calendar", "Oldest", column: "avg_age",
            category: .population, kind: .rangeHigh, ascending: false,
            filter: "\(pop) AND avg_age <= 100", displayKind: .age, pairKey: "age") { "\(Int($0.rounded()))" }
        top("ageYoung", "calendar", "Youngest", column: "avg_age",
            category: .population, kind: .rangeLow, ascending: true,
            filter: "\(popStrict) AND avg_age >= 5", displayKind: .age, pairKey: "age") { "\(Int($0.rounded()))" }

        return facts
    }

    /// Offline precinct-name search within a state (e.g. "7602", "AD 65").
    public func searchPrecincts(state: String, query: String, limit: Int = 15)
        -> [(name: String, borough: String, lat: Double, lon: Double)] {
        let sql = """
            SELECT precinct_name, COALESCE(borough, ''),
                   (min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0
            FROM precincts
            WHERE state = ? AND precinct_name IS NOT NULL AND precinct_name LIKE ?
            ORDER BY precinct_name LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, "%\(query)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [(name: String, borough: String, lat: Double, lon: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let n = text(stmt, 0) else { continue }
            out.append((n, text(stmt, 1) ?? "", sqlite3_column_double(stmt, 3), sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    /// The top precincts for a fact, ranked by that fact's own metric (the "see all" list). Uses the
    /// SAME scope + size/sanity filter as the card, so the surfaced winner is row 1. Lazy — only
    /// called when the user taps "see all". Population breaks ties so the order is deterministic.
    public func topPrecincts(_ spec: LeaderboardSpec, limit: Int = 25) -> [LeaderRow] {
        let scope = spec.county == nil ? "state = ?" : "state = ? AND borough = ?"
        let scopeBinds = spec.county.map { [spec.state, $0] } ?? [spec.state]
        let sql = """
            SELECT unit_id, borough, state, precinct_name, \(spec.valueColumn),
                   (min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0
            FROM precincts
            WHERE \(scope) AND \(spec.baseFilter) AND (\(spec.orderExpr)) IS NOT NULL
            ORDER BY (\(spec.orderExpr)) \(spec.ascending ? "ASC" : "DESC"), pop_total DESC, unit_id ASC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindTexts(stmt, scopeBinds)
        sqlite3_bind_int(stmt, Int32(scopeBinds.count + 1), Int32(limit))   // LIMIT ? follows the scope binds
        var out: [LeaderRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uid = text(stmt, 0) else { continue }
            out.append(LeaderRow(id: uid, borough: text(stmt, 1) ?? "", state: text(stmt, 2) ?? "",
                                 precinctName: text(stmt, 3) ?? "",
                                 value: sqlite3_column_double(stmt, 4),
                                 lat: sqlite3_column_double(stmt, 6), lon: sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    // MARK: Row -> profile

    private func row(id: Int32) -> (PrecinctProfile, Data)? {
        let sql = """
            SELECT unit_id, borough, state, precinct_name,
                   lean_label, lean_dem_share, prev_dem_share, lean_year, prev_year, lean_shift, lean_votes, turnout_est,
                   pop_total, vap_total, cvap,
                   pct_white, pct_black, pct_hispanic, pct_asian, pct_native, pct_pacific, pct_other,
                   plurality_group,
                   pct_no_hs, pct_hs, pct_bachelors, pct_graduate, pct_ba_or_higher,
                   income_median, pop_density, avg_age, pct_renter, pct_owner, data_complete,
                   geometry_wkb
            FROM precincts WHERE rowid = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let unitID = text(stmt, 0), let wkb = blob(stmt, 34) else { return nil }

        let profile = PrecinctProfile(
            unitID: unitID, borough: text(stmt, 1) ?? "", state: text(stmt, 2) ?? "",
            precinctName: text(stmt, 3),
            leanLabel: text(stmt, 4), leanDemShare: dbl(stmt, 5), prevDemShare: dbl(stmt, 6),
            leanYear: int(stmt, 7), prevYear: int(stmt, 8), leanShift: dbl(stmt, 9),
            leanVotes: int(stmt, 10), turnoutEst: dbl(stmt, 11),
            popTotal: int(stmt, 12), vapTotal: int(stmt, 13), cvap: int(stmt, 14),
            pctWhite: dbl(stmt, 15), pctBlack: dbl(stmt, 16), pctHispanic: dbl(stmt, 17),
            pctAsian: dbl(stmt, 18), pctNative: dbl(stmt, 19), pctPacific: dbl(stmt, 20),
            pctOther: dbl(stmt, 21), pluralityGroup: text(stmt, 22),
            pctNoHS: dbl(stmt, 23), pctHS: dbl(stmt, 24), pctBachelors: dbl(stmt, 25),
            pctGraduate: dbl(stmt, 26), pctBachelorsOrHigher: dbl(stmt, 27),
            incomeMedian: int(stmt, 28), popDensity: dbl(stmt, 29), avgAge: dbl(stmt, 30),
            pctRenter: dbl(stmt, 31), pctOwner: dbl(stmt, 32),
            dataComplete: (int(stmt, 33) ?? 0) == 1)
        return (profile, wkb)
    }

    // MARK: Column helpers

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i)
        else { return nil }
        return String(cString: c)
    }
    private func dbl(_ s: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
    private func int(_ s: OpaquePointer?, _ i: Int32) -> Int? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
    }
    private func blob(_ s: OpaquePointer?, _ i: Int32) -> Data? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let b = sqlite3_column_blob(s, i)
        else { return nil }
        return Data(bytes: b, count: Int(sqlite3_column_bytes(s, i)))
    }
    /// Bind runtime scope values (state, optional county) as text parameters 1...n. Scope
    /// placeholders must be the FIRST `?`s in the statement; column/order expressions stay
    /// interpolated because they are compile-time constants (identifiers can't be bound).
    private func bindTexts(_ stmt: OpaquePointer?, _ values: [String]) {
        for (i, v) in values.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
    }
}
