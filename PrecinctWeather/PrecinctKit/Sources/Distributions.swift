import Foundation
import SQLite3

// MARK: - Metric distributions
//
// The By the Numbers charts, rankings and ties. Every metric counts, ranks and ties on its printed
// value with one size filter (100 votes for election measures, 500 people for census measures),
// so a chart and its ranked list always agree.

public enum Metric: String, CaseIterable, Identifiable, Sendable {
    case lean, shift, turnout, largestGroup, income, college, renters, age, density

    public var id: String { rawValue }

    /// Short label for chips.
    public var title: String {
        switch self {
        case .lean: return "Lean"
        case .shift: return "Shift"
        case .turnout: return "Turnout"
        case .largestGroup: return "Largest group"
        case .income: return "Income"
        case .college: return "College"
        case .renters: return "Renters"
        case .age: return "Age"
        case .density: return "Density"
        }
    }

    /// Chart heading.
    public var question: String {
        switch self {
        case .lean: return "How precincts lean"
        case .shift: return "How far precincts swung"
        case .turnout: return "How many eligible adults voted"
        case .largestGroup: return "Which group is largest"
        case .income: return "Median household income"
        case .college: return "Adults with a college degree"
        case .renters: return "Renters and owners"
        case .age: return "Median age"
        case .density: return "People per square mile"
        }
    }

    public var bucketLabels: [String] { bins.map(\.label) }
    public var bucketDetails: [String]? {
        let d = bins.map(\.detail)
        return d.allSatisfy(\.isEmpty) ? nil : d
    }

    /// Lean colors for the two election measures, nil (ink) for everything else.
    public func leanShare(bucket i: Int) -> Double? { bins.indices.contains(i) ? bins[i].leanShare : nil }

    public func format(_ v: Double) -> String {
        switch self {
        case .lean:
            let m = Int(((v - 0.5) * 200).rounded())
            return m > 0 ? "D+\(m)" : m < 0 ? "R+\(-m)" : "Even"
        case .shift:
            // The value is already whole margin points (see `column`), with the direction, so a
            // list or an extreme never shows a swing without saying which way it went.
            let p = Int(abs(v).rounded())
            return p == 0 ? "No change" : "\(p) \(p == 1 ? "point" : "points") toward \(v > 0 ? "D" : "R")"
        case .turnout, .college, .renters:
            return "\(Int((min(v, 1) * 100).rounded()))%"
        case .income:
            return v >= 250001 ? "$250k+" : "$\(Int(v).formatted())"
        case .age:
            return "\(Int(v.rounded()))"
        case .density:
            // Whole people under 1k, tenths of a thousand above, from the same rounding as the
            // `column`, so the text and the value it ranks on are one number. Integer math
            // avoids printf rounding, which can disagree with ROUND at an exact .05.
            let d = Self.displayedDensity(v)
            guard d >= 1000 else { return "\(Int(d))" }
            let tenths = Int((d / 100).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        case .largestGroup:
            return ""
        }
    }

    /// Density as printed: whole people below 999.5, else rounded to the nearest 100.
    static func displayedDensity(_ v: Double) -> Double {
        v < 999.5 ? v.rounded() : (v / 100).rounded() * 100
    }

    var column: String {
        switch self {
        // The share snapped to the printed margin: 0.5 + m / 200, where m is the whole margin
        // shown as D+m or R+m. It ranks, ties and counts exactly like m, and stays in share units
        // so `format`, the lean colors and every share-based caller keep working.
        case .lean: return "(0.5 + ROUND((lean_dem_share - 0.5) * 200) / 200.0)"
        // Whole margin points: the later rounded margin minus the earlier rounded margin, the
        // same two numbers the sentence prints ("from D+36 to R+10" is 46). Bins, ranking, ties
        // and the percentile all use it, so every shift number on the page has one definition.
        // SQLite ROUND and Swift rounded() both round halves away from zero. A precinct with no
        // earlier result gives NULL and drops out, as it did with lean_shift.
        case .shift: return "(ROUND((lean_dem_share - 0.5) * 200) - ROUND((prev_dem_share - 0.5) * 200))"
        // The whole percent a reader sees, capped at 100%, so bins, ranking, ties, the percentile
        // and the extremes all use the displayed number. The filter still drops rows above 1.05
        // on the raw column. SQLite ROUND and Swift rounded() both round halves away from zero.
        case .turnout: return "(ROUND(MIN(turnout_est, 1.0) * 100) / 100.0)"
        case .largestGroup: return "plurality_group"
        case .income: return "income_median"
        // Percents, age and density rank on the number as printed, like turnout and shift, so two
        // precincts that read the same are tied and a bar never holds a value its label excludes.
        case .college: return "(ROUND(pct_ba_or_higher * 100) / 100.0)"
        case .renters: return "(ROUND(pct_renter * 100) / 100.0)"
        case .age: return "ROUND(avg_age)"
        case .density: return "(CASE WHEN pop_density < 999.5 THEN ROUND(pop_density) ELSE ROUND(pop_density / 100.0) * 100 END)"
        }
    }

    var filter: String {
        switch self {
        case .lean, .shift: return "lean_votes >= 100"
        case .turnout: return "lean_votes >= 100 AND turnout_est <= 1.05"
        default: return "pop_total >= 500"
        }
    }

    struct Bin {
        let label: String
        let detail: String
        let condition: String      // SQL where the token `v` stands for the column
        let leanShare: Double?
        let groups: [String]
    }

    var bins: [Bin] {
        func b(_ l: String, _ d: String, _ c: String, _ s: Double? = nil) -> Bin {
            Bin(label: l, detail: d, condition: c, leanShare: s, groups: [])
        }
        switch self {
        case .lean:
            // Bins test the whole printed margin, so a precinct shown as D+10 is always Lean D.
            let m = "ROUND((v - 0.5) * 200)"
            return [b("Solid D", "D+30 or more", "\(m) >= 30", 0.8), b("Lean D", "D+10 to 29", "\(m) >= 10 AND \(m) < 30", 0.6),
                    b("Even", "under 10", "\(m) > -10 AND \(m) < 10", 0.5), b("Lean R", "R+10 to 29", "\(m) > -30 AND \(m) <= -10", 0.4),
                    b("Solid R", "R+30 or more", "\(m) <= -30", 0.2)]
        case .shift:
            // The value is the change in whole margin points, the unit of D+36 and R+10.
            return [b("Toward D", "15+ points", "v >= 15", 0.75), b("Slightly D", "5 to 14", "v >= 5 AND v < 15", 0.6),
                    b("Steady", "under 5", "v > -5 AND v < 5", 0.5), b("Slightly R", "5 to 14", "v > -15 AND v <= -5", 0.4),
                    b("Toward R", "15+ points", "v <= -15", 0.25)]
        case .turnout:
            return [b("Under 40%", "", "v < 0.40"), b("40 to 55%", "", "v >= 0.40 AND v < 0.55"),
                    b("55 to 70%", "", "v >= 0.55 AND v < 0.70"), b("70 to 85%", "", "v >= 0.70 AND v < 0.85"),
                    b("85%+", "", "v >= 0.85")]
        case .largestGroup:
            func g(_ l: String, _ names: [String]) -> Bin {
                Bin(label: l, detail: "", condition: "v IN (\(names.map { "'\($0)'" }.joined(separator: ",")))",
                    leanShare: nil, groups: names)
            }
            return [g("White", ["White"]), g("Hispanic", ["Hispanic"]), g("Black", ["Black"]), g("Asian", ["Asian"]),
                    g("Other", ["Native", "Pacific", "Other"])]
        case .income:
            return [b("Under $50k", "", "v < 50000"), b("$50k to 75k", "", "v >= 50000 AND v < 75000"),
                    b("$75k to 100k", "", "v >= 75000 AND v < 100000"), b("$100k to 150k", "", "v >= 100000 AND v < 150000"),
                    b("$150k+", "", "v >= 150000")]
        case .college, .renters:
            return [b("Under 20%", "", "v < 0.2"), b("20 to 40%", "", "v >= 0.2 AND v < 0.4"), b("40 to 60%", "", "v >= 0.4 AND v < 0.6"),
                    b("60 to 80%", "", "v >= 0.6 AND v < 0.8"), b("80%+", "", "v >= 0.8")]
        case .age:
            return [b("Under 30", "", "v < 30"), b("30 to 35", "", "v >= 30 AND v < 35"), b("35 to 40", "", "v >= 35 AND v < 40"),
                    b("40 to 45", "", "v >= 40 AND v < 45"), b("45+", "", "v >= 45")]
        case .density:
            return [b("Under 1k", "", "v < 1000"), b("1k to 5k", "", "v >= 1000 AND v < 5000"),
                    b("5k to 20k", "", "v >= 5000 AND v < 20000"), b("20k to 50k", "", "v >= 20000 AND v < 50000"),
                    b("50k+", "", "v >= 50000")]
        }
    }

    func sql(_ condition: String) -> String {
        condition.replacingOccurrences(of: "\\bv\\b", with: column, options: .regularExpression)
    }

    /// Each precinct's own largest share, so a list ranks by the share of whichever group is
    /// largest there. The Other bucket mixes Native, Pacific and other, so it cannot use one column.
    static let pluralityShare = "CASE plurality_group WHEN 'White' THEN pct_white WHEN 'Hispanic' THEN pct_hispanic "
        + "WHEN 'Black' THEN pct_black WHEN 'Asian' THEN pct_asian WHEN 'Native' THEN pct_native "
        + "WHEN 'Pacific' THEN pct_pacific ELSE pct_other END"
}

public struct Distribution: Sendable {
    public let metric: Metric
    public let counts: [Int]
    public let total: Int
    /// Bucket holding the selected precinct, when it is in scope and passes the metric's filter.
    public let selectedBucket: Int?
    public let selectedValue: Double?
    /// Share of precincts in scope with a lower value than the selected one.
    public let selectedPercentile: Double?
    /// Share of precincts in scope with a higher value than the selected one.
    public let selectedAbove: Double?
}

public struct RankedPrecinct: Identifiable, Sendable {
    public var id: String { unitID }
    public let unitID: String
    public let borough: String
    public let precinctName: String?
    public let value: Double?
    /// Text value for the categorical largest-group metric.
    public let label: String?
    public let lat: Double
    public let lon: Double
}

extension PrecinctDB {
    private func scopeSQL(state: String, county: String?, prefixes: [String]) -> (String, [String]) {
        if !prefixes.isEmpty {
            return ("(" + prefixes.map { _ in "unit_id LIKE ?" }.joined(separator: " OR ") + ")", prefixes.map { "\($0)-%" })
        }
        return county == nil ? ("state = ?", [state]) : ("state = ? AND borough = ?", [state, county!])
    }

    private func run(_ sql: String, _ texts: [String], doubles: [Double] = [], _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in texts.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) }
        for (i, v) in doubles.enumerated() { sqlite3_bind_double(stmt, Int32(texts.count + i + 1), v) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        sqlite3_finalize(stmt)
    }

    private static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    public func distribution(_ metric: Metric, state: String, county: String?, prefixes: [String] = [],
                             selectedUnitID: String?) -> Distribution {
        let (scope, binds) = scopeSQL(state: state, county: county, prefixes: prefixes)
        let col = metric.column
        let cases = metric.bins.enumerated().map { "WHEN \(metric.sql($0.element.condition)) THEN \($0.offset)" }
            .joined(separator: " ")
        var counts = Array(repeating: 0, count: metric.bins.count)
        run("""
            SELECT CASE \(cases) ELSE -1 END AS b, COUNT(*) FROM precincts
            WHERE \(scope) AND \(metric.filter) AND \(col) IS NOT NULL GROUP BY b
            """, binds) { s in
            let b = Int(sqlite3_column_int(s, 0))
            if counts.indices.contains(b) { counts[b] += Int(sqlite3_column_int(s, 1)) }
        }
        let total = counts.reduce(0, +)

        var bucket: Int?, value: Double?, percentile: Double?, above: Double?
        if let unitID = selectedUnitID {
            run("""
                SELECT CASE \(cases) ELSE -1 END, \(metric == .largestGroup ? "NULL" : col) FROM precincts
                WHERE unit_id = ? AND \(scope) AND \(metric.filter) AND \(col) IS NOT NULL
                """, [unitID] + binds) { s in
                let b = Int(sqlite3_column_int(s, 0))
                bucket = b >= 0 ? b : nil
                if sqlite3_column_type(s, 1) != SQLITE_NULL { value = sqlite3_column_double(s, 1) }
            }
            if let v = value, total > 0 {
                run("SELECT COUNT(*) FROM precincts WHERE \(scope) AND \(metric.filter) AND \(col) < ?",
                    binds, doubles: [v]) { s in
                    percentile = Double(sqlite3_column_int(s, 0)) / Double(total)
                }
                run("SELECT COUNT(*) FROM precincts WHERE \(scope) AND \(metric.filter) AND \(col) > ?",
                    binds, doubles: [v]) { s in
                    above = Double(sqlite3_column_int(s, 0)) / Double(total)
                }
            }
        }
        return Distribution(metric: metric, counts: counts, total: total,
                            selectedBucket: bucket, selectedValue: value, selectedPercentile: percentile,
                            selectedAbove: above)
    }

    /// Which pair of presidential elections the shift compares in this area, most common first.
    public func shiftYears(state: String, county: String?, prefixes: [String] = []) -> [(from: Int, to: Int, count: Int)] {
        let (scope, binds) = scopeSQL(state: state, county: county, prefixes: prefixes)
        var out: [(Int, Int, Int)] = []
        run("""
            SELECT prev_year, lean_year, COUNT(*) FROM precincts
            WHERE \(scope) AND lean_votes >= 100 AND lean_shift IS NOT NULL
            GROUP BY 1, 2 ORDER BY 3 DESC
            """, binds) { s in
            out.append((Int(sqlite3_column_int(s, 0)), Int(sqlite3_column_int(s, 1)), Int(sqlite3_column_int(s, 2))))
        }
        return out.map { (from: $0.0, to: $0.1, count: $0.2) }
    }

    /// How many precincts share the given value, so a highest or lowest that is really a tie
    /// can say so instead of naming one precinct.
    public func tieCount(_ metric: Metric, value: Double, state: String, county: String?, prefixes: [String] = []) -> Int {
        let (scope, binds) = scopeSQL(state: state, county: county, prefixes: prefixes)
        var n = 0
        run("SELECT COUNT(*) FROM precincts WHERE \(scope) AND \(metric.filter) AND ABS(\(metric.column) - ?) < 1e-9",
            binds, doubles: [value]) { s in n = Int(sqlite3_column_int(s, 0)) }
        return n
    }

    /// Precincts in scope, optionally inside one bucket, ordered by the metric. Inside a
    /// largest-group bucket the order is that group's own share.
    public func ranked(_ metric: Metric, state: String, county: String?, prefixes: [String] = [],
                       bucket: Int?, ascending: Bool = false, limit: Int = 40) -> [RankedPrecinct] {
        let (scope, binds) = scopeSQL(state: state, county: county, prefixes: prefixes)
        let col = metric.column
        var conds = [scope, metric.filter, "\(col) IS NOT NULL"]
        var order = col
        if let bucket, metric.bins.indices.contains(bucket) {
            conds.append("(\(metric.sql(metric.bins[bucket].condition)))")
            if metric == .largestGroup { order = Metric.pluralityShare }
        } else if metric == .largestGroup {
            // Each precinct's own largest share, so the list reads "most White", "most Hispanic"
            // and so on in one ranking.
            order = Metric.pluralityShare
        }
        let valueExpr = metric == .largestGroup ? order : col
        var rows: [RankedPrecinct] = []
        run("""
            SELECT unit_id, borough, precinct_name, \(valueExpr), plurality_group,
                   (min_lon + max_lon) / 2.0, (min_lat + max_lat) / 2.0
            FROM precincts WHERE \(conds.joined(separator: " AND "))
            ORDER BY \(order) \(ascending ? "ASC" : "DESC"), unit_id LIMIT \(max(1, min(limit, 200)))
            """, binds) { s in
            let isGroup = metric == .largestGroup
            rows.append(RankedPrecinct(
                unitID: Self.str(s, 0) ?? "", borough: Self.str(s, 1) ?? "", precinctName: Self.str(s, 2),
                value: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_double(s, 3),
                label: isGroup ? Self.str(s, 4) : nil,
                lat: sqlite3_column_double(s, 6), lon: sqlite3_column_double(s, 5)))
        }
        return rows
    }
}

// MARK: - Lean group

/// The lean group for a whole printed margin (positive is D), in the database's label words.
/// The same cut points as the By the Numbers lean chart: 30 and 10. The bundled `lean_label`
/// uses raw-share thresholds, so a precinct printed D+10 can carry "Even". Show this instead
/// wherever a label sits next to a printed margin.
public func leanGroupLabel(forMargin m: Int) -> String {
    if m >= 30 { return "Solid Dem" }
    if m >= 10 { return "Lean Dem" }
    if m > -10 { return "Even" }
    if m > -30 { return "Lean Rep" }
    return "Solid Rep"
}

/// The whole printed margin for a two-party Democratic share, as `Metric.lean.format` prints it.
public func printedMargin(share: Double) -> Int {
    Int(((share - 0.5) * 200).rounded())
}

// MARK: - Reader-facing wording
//
// Kept here, next to the numbers, so the tests can check the exact words a reader sees.

extension Metric {
    /// Title over one end of the chart. Lean and shift name a side, so when every precinct in
    /// the area sits on one side the title says "least" or "smallest" instead of naming the
    /// wrong party.
    public func extremeTitle(highest: Bool, value: Double?) -> String {
        let v = value ?? 0
        switch self {
        case .lean:
            if highest { return v < 0.5 ? "Least Republican" : "Most Democratic" }
            return v > 0.5 ? "Least Democratic" : "Most Republican"
        case .shift:
            if highest { return v > 0 ? "Biggest swing toward D" : "Smallest swing toward R" }
            return v < 0 ? "Biggest swing toward R" : "Smallest swing toward D"
        default:
            return highest ? "Highest" : "Lowest"
        }
    }
}

extension Distribution {
    /// Label over one bar. A bar with precincts in it never reads "0%".
    public func percentLabel(bucket i: Int) -> String {
        let count = counts.indices.contains(i) ? counts[i] : 0
        let pct = Int((Double(count) / Double(max(1, total)) * 100).rounded())
        return count > 0 && pct == 0 ? "<1%" : "\(pct)%"
    }

    /// One plain sentence placing the selected precinct in the distribution. The wording lives
    /// here, next to the numbers, so the tests check the exact sentence.
    public func youSentence(place: String?, scope: String, profile: PrecinctProfile? = nil) -> String? {
        guard let place, let bucket = selectedBucket else { return nil }
        switch metric {
        case .lean:
            return "\(place) is \(selectedValue.map { metric.format($0) } ?? ""), in the \(metric.bucketLabels[bucket]) group."
        case .largestGroup:
            // The You tag already marks the group, so the sentence adds its share.
            let group = metric.bucketLabels[bucket]
            if let share = profile?.raceBreakdown.first(where: { $0.label == group })?.value {
                return "In \(place), the largest group is \(group), at \(Int((share * 100).rounded()))% of residents."
            }
            return "In \(place), the largest group is \(group)."
        case .shift:
            guard let v = selectedValue, let p = selectedPercentile else { return nil }
            // v is the difference of the two rounded margins, so it matches the pair printed here.
            let pts = Int(abs(v).rounded())
            var fromTo = ""
            if let prof = profile, let a = prof.prevDemShare, let b = prof.leanDemShare,
               let y0 = prof.prevYear, let y1 = prof.leanYear {
                fromTo = ", from \(Metric.lean.format(a)) in \(y0) to \(Metric.lean.format(b)) in \(y1)"
            }
            if pts < 1 { return "\(place) voted almost the same as the election before." }
            let side = v > 0 ? "Democrats" : "Republicans"
            let s = "\(place) swung \(pts) \(pts == 1 ? "point" : "points") toward \(side)" + fromTo
            // Share of precincts that swung strictly further the same way.
            let share = v > 0 ? (selectedAbove ?? 1 - p) : p
            let further = Int((share * 100).rounded())
            // The same words as the bars and the first sentence, and never a sentence that
            // starts with a numeral.
            let dir = "toward \(side)"
            if share == 0 { return s + ". No precinct in \(scope) swung further \(dir)." }
            if further < 1 { return s + ". Almost no precinct in \(scope) swung further \(dir)." }
            return s + (further < 50 ? ". Only \(further)% of precincts in \(scope) swung further \(dir)."
                                     : ". In \(scope), \(further)% of precincts swung further \(dir).")
        default:
            guard let v = selectedValue, let p = selectedPercentile else { return nil }
            // Say what the number measures, so the sentence reads on its own.
            let value = metric.format(v)
            let head: String
            switch metric {
            case .turnout: head = "\(place) had \(value) turnout"
            case .income: head = "\(place) has a median household income of \(value)"
            case .college: head = "In \(place), \(value) of adults have a college degree"
            case .renters: head = "In \(place), \(value) of homes are rented"
            case .age: head = "\(place) has a median age of \(value)"
            case .density: head = "\(place) has \(value) people per square mile"
            default: head = "\(place) is at \(value)"
            }
            let above = selectedAbove ?? max(0, 1 - p)
            let tied = total > 0 && Int((Double(total) * (1 - p - above)).rounded()) > 1
            if above == 0 { return head + (tied ? ", tied for the highest in \(scope)." : ", the highest in \(scope).") }
            if p == 0 { return head + (tied ? ", tied for the lowest in \(scope)." : ", the lowest in \(scope).") }
            // Name the larger side, so a low value reads "lower than 99%" and not "higher than 1%"
            // right after another percent.
            if p < 0.5 {
                let pct = min(99, max(1, Int((above * 100).rounded())))
                return head + ", lower than \(pct)% of precincts in \(scope)."
            }
            let pct = min(99, max(1, Int((p * 100).rounded())))
            return head + ", higher than \(pct)% of precincts in \(scope)."
        }
    }
}
