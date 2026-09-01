import Foundation

/// Which grouped section a fact belongs to on the "By the Numbers" page.
public enum FactCategory: String, CaseIterable, Sendable {
    case politics, race, wealth, education, population

    /// Section header text (editorial/serif in the UI).
    public var title: String {
        switch self {
        case .politics:   return "Politics"
        case .race:       return "Race & demographics"
        case .wealth:     return "Wealth & housing"
        case .education:  return "Education"
        case .population: return "Population & age"
        }
    }
}

/// How a fact should be rendered.
public enum FactKind: Sendable {
    case leaderboard   // single superlative card
    case insight       // single card with an explanatory subtitle
    case rangeLow      // low end of a min↔max pair (fused with its rangeHigh by pairKey)
    case rangeHigh     // high end of a min↔max pair
}

/// A "superlative"/insight computed from the dataset, with the coordinate to jump the map there.
/// `lat`/`lon` are nil for non-tappable aggregate rows.
public struct FunFact: Identifiable, Sendable {
    public let id: String
    public let icon: String          // SF Symbol
    public let title: String
    public let value: String
    public let place: String         // "borough, state (precinct)"
    public let unitID: String?       // exact winner, so taps select by id instead of bbox center
    public let lat: Double?
    public let lon: Double?
    public let category: FactCategory
    public let kind: FactKind
    public let pairKey: String?      // rangeLow + rangeHigh sharing a pairKey fuse into one RangeRow
    public let subtitle: String?     // one-line explanation for .insight facts
    public let tieCount: Int?        // precincts sharing this exact displayed value (cap/ceiling ties); nil = unique
    public let leaderboard: LeaderboardSpec?   // present iff there's a crowd to drill into

    public init(id: String, icon: String, title: String, value: String,
                place: String, unitID: String? = nil, lat: Double?, lon: Double?,
                category: FactCategory, kind: FactKind,
                pairKey: String? = nil, subtitle: String? = nil,
                tieCount: Int? = nil, leaderboard: LeaderboardSpec? = nil) {
        self.id = id; self.icon = icon; self.title = title; self.value = value
        self.place = place; self.unitID = unitID; self.lat = lat; self.lon = lon
        self.category = category; self.kind = kind
        self.pairKey = pairKey; self.subtitle = subtitle
        self.tieCount = tieCount; self.leaderboard = leaderboard
    }
}

/// Everything needed to query + present a fact's full "see all" ranked list. Built for every
/// rankable fact: tapping a superlative pushes the top 25 precincts ordered by that fact's own
/// metric (so ties stop mattering — you see the whole ranking, not one arbitrary winner).
public struct LeaderboardSpec: Hashable, Identifiable, Sendable {
    public let factID: String
    public let title: String
    public let note: String           // honest header (why they tie at a cap, or just "the top precincts here")
    public let state: String
    public let county: String?
    public let unitIDPrefixes: [String]
    public let valueColumn: String    // column shown per row (e.g. "income_median", "pct_renter")
    public let orderExpr: String      // SQL expression to rank by (usually == valueColumn)
    public let baseFilter: String     // the fact's own size/sanity filter, e.g. "pop_total >= 500"
    public let ascending: Bool        // rank direction (true = smallest first, e.g. "lowest income")
    public let displayKind: ValueKind
    public var id: String { "\(factID)|\(state)|\(county ?? "")" }

    public enum ValueKind: String, Hashable, Sendable { case money, pct, age, density, lean, shiftPts }

    public init(factID: String, title: String, note: String, state: String, county: String?,
                valueColumn: String, orderExpr: String? = nil, baseFilter: String,
                ascending: Bool, displayKind: ValueKind, unitIDPrefixes: [String] = []) {
        self.factID = factID; self.title = title; self.note = note
        self.state = state; self.county = county; self.unitIDPrefixes = unitIDPrefixes
        self.valueColumn = valueColumn; self.orderExpr = orderExpr ?? valueColumn
        self.baseFilter = baseFilter; self.ascending = ascending; self.displayKind = displayKind
    }
}

/// One row of a leaderboard list (a precinct tied at the extreme), with the coordinate to jump there.
public struct LeaderRow: Identifiable, Sendable {
    public let id: String            // unit_id
    public let borough: String
    public let state: String
    public let precinctName: String
    public let value: Double
    public let lat: Double
    public let lon: Double
    public init(id: String, borough: String, state: String, precinctName: String,
                value: Double, lat: Double, lon: Double) {
        self.id = id; self.borough = borough; self.state = state; self.precinctName = precinctName
        self.value = value; self.lat = lat; self.lon = lon
    }
}

/// One segment of the lean-distribution bar (Solid Rep … Even … Solid Dem).
public struct LeanBucket: Identifiable, Sendable {
    public let label: String
    public let count: Int
    public var id: String { label }
    public init(label: String, count: Int) { self.label = label; self.count = count }
}

/// Scope-level aggregate shown at the top of the page (not tappable).
public struct ScopeOverview: Sendable {
    public let precinctCount: Int
    public let totalPopulation: Int?
    public let avgDemShare: Double?        // 0...1, latest presidential two-party Dem share
    public let medianIncome: Int?
    public let leanBuckets: [LeanBucket]   // ordered Solid Rep → Lean Rep → Even → Lean Dem → Solid Dem

    public init(precinctCount: Int, totalPopulation: Int?, avgDemShare: Double?,
                medianIncome: Int?, leanBuckets: [LeanBucket]) {
        self.precinctCount = precinctCount
        self.totalPopulation = totalPopulation
        self.avgDemShare = avgDemShare
        self.medianIncome = medianIncome
        self.leanBuckets = leanBuckets
    }
}
