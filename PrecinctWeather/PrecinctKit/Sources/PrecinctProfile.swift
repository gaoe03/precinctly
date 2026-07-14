import Foundation

/// Single source of truth for the coverage recital. Five surfaces (toasts, onboarding,
/// Settings, the widget placeholder) read these, so adding a state is a one-line change.
public enum Coverage {
    /// Abbreviated list for tight surfaces (toasts, widgets).
    public static let abbrList = "NY, CA, MA, and TX"
    /// Full-name sentence for calm surfaces (onboarding, Settings).
    public static let namesSentence = "Precinct covers New York, California, Massachusetts, and Texas, with more states coming."
}

/// TX (and some CA) precinct names are zero-padded election ids ("000363"); strip the
/// padding at display time so titles read "Precinct 363", not machine output. Names that
/// don't start with a zero ("AD 65 ED 21", "Chatham Town Precinct 1") pass through.
public func precinctDisplayName(_ raw: String) -> String {
    guard raw.hasPrefix("0") else { return raw }
    let stripped = raw.drop(while: { $0 == "0" })
    return stripped.isEmpty ? "0" : String(stripped)
}

/// The `borough` column holds a bare county name everywhere except NYC, where it's a borough
/// name. Append " County" for display — but never to the 5 NYC boroughs (you'd get the wrong /
/// awkward name, e.g. "Brooklyn County" instead of Kings County).
public func countyDisplay(_ borough: String) -> String {
    let nycBoroughs: Set<String> = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"]
    guard !borough.isEmpty, !nycBoroughs.contains(borough) else { return borough }
    let lower = borough.lowercased()
    guard !lower.hasSuffix("county"), !lower.hasSuffix("city"), !lower.hasSuffix("borough") else { return borough }
    return "\(borough) County"
}

/// Display-ready profile for a single precinct. Mirrors the precomputed columns
/// in the bundled SQLite. Codable so it can be cached in the App Group.
public struct PrecinctProfile: Codable, Equatable, Sendable {
    public let unitID: String
    public let borough: String        // NYC borough name, or county elsewhere
    public let state: String          // state_abbr, e.g. "NY", "CA", "MA"
    public let precinctName: String?

    // Political lean — based on the most recent presidential election available
    // for this precinct (2024 in most states; 2020 in California).
    public let leanLabel: String?
    public let leanDemShare: Double?  // latest president, two-party Dem share 0...1
    public let prevDemShare: Double?  // the prior president
    public let leanYear: Int?
    public let prevYear: Int?
    public let leanShift: Double?     // latest - prev (negative = moved right)
    public let leanVotes: Int?
    public let turnoutEst: Double?

    // Demographics (fractions 0...1 unless noted)
    public let popTotal: Int?
    public let vapTotal: Int?
    public let cvap: Int?
    public let pctWhite: Double?
    public let pctBlack: Double?
    public let pctHispanic: Double?
    public let pctAsian: Double?
    public let pctNative: Double?
    public let pctPacific: Double?
    public let pctOther: Double?
    public let pluralityGroup: String?
    public let pctNoHS: Double?
    public let pctHS: Double?
    public let pctBachelors: Double?
    public let pctGraduate: Double?
    public let pctBachelorsOrHigher: Double?
    public let incomeMedian: Int?
    public let popDensity: Double?
    public let avgAge: Double?
    public let pctRenter: Double?
    public let pctOwner: Double?
    public let dataComplete: Bool

    public init(unitID: String, borough: String, state: String, precinctName: String?,
                leanLabel: String?, leanDemShare: Double?, prevDemShare: Double?,
                leanYear: Int?, prevYear: Int?, leanShift: Double?, leanVotes: Int?,
                turnoutEst: Double?,
                popTotal: Int?, vapTotal: Int?, cvap: Int?,
                pctWhite: Double?, pctBlack: Double?, pctHispanic: Double?,
                pctAsian: Double?, pctNative: Double?, pctPacific: Double?, pctOther: Double?,
                pluralityGroup: String?,
                pctNoHS: Double?, pctHS: Double?, pctBachelors: Double?, pctGraduate: Double?,
                pctBachelorsOrHigher: Double?, incomeMedian: Int?, popDensity: Double?,
                avgAge: Double?, pctRenter: Double?, pctOwner: Double?, dataComplete: Bool) {
        self.unitID = unitID; self.borough = borough; self.state = state
        self.precinctName = precinctName
        self.leanLabel = leanLabel; self.leanDemShare = leanDemShare
        self.prevDemShare = prevDemShare; self.leanYear = leanYear; self.prevYear = prevYear
        self.leanShift = leanShift; self.leanVotes = leanVotes; self.turnoutEst = turnoutEst
        self.popTotal = popTotal; self.vapTotal = vapTotal; self.cvap = cvap
        self.pctWhite = pctWhite; self.pctBlack = pctBlack; self.pctHispanic = pctHispanic
        self.pctAsian = pctAsian; self.pctNative = pctNative; self.pctPacific = pctPacific
        self.pctOther = pctOther; self.pluralityGroup = pluralityGroup
        self.pctNoHS = pctNoHS; self.pctHS = pctHS; self.pctBachelors = pctBachelors
        self.pctGraduate = pctGraduate; self.pctBachelorsOrHigher = pctBachelorsOrHigher
        self.incomeMedian = incomeMedian; self.popDensity = popDensity
        self.avgAge = avgAge; self.pctRenter = pctRenter; self.pctOwner = pctOwner
        self.dataComplete = dataComplete
    }

    public var raceBreakdown: [(label: String, value: Double)] {
        let pairs: [(String, Double?)] = [
            ("White", pctWhite), ("Black", pctBlack), ("Hispanic", pctHispanic),
            ("Asian", pctAsian), ("Native", pctNative), ("Pacific", pctPacific),
            ("Other race", pctOther),   // Census "Some Other Race" — Hispanic respondents often pick this
        ]
        return pairs.compactMap { l, v in v.map { (l, $0) } }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    /// e.g. "D+18" / "R+5" / "Even" from the latest available president. Tight form matches the
    /// trajectory bars, By-the-Numbers, the widgets, and the site.
    public var leanShort: String {
        guard let s = leanDemShare else { return "—" }
        let margin = Int((abs(s - 0.5) * 200).rounded())
        if margin < 1 { return "Even" }
        return (s >= 0.5 ? "D+" : "R+") + "\(margin)"
    }

    public static let sample = PrecinctProfile(
        unitID: "36061-:-0065021", borough: "Manhattan", state: "NY", precinctName: "AD 65 ED 21",
        leanLabel: "Solid Dem", leanDemShare: 0.681, prevDemShare: 0.773,
        leanYear: 2024, prevYear: 2020, leanShift: -0.092, leanVotes: 574, turnoutEst: 0.35,
        popTotal: 2624, vapTotal: 2331, cvap: 1617,
        pctWhite: 0.129, pctBlack: 0.006, pctHispanic: 0.038,
        pctAsian: 0.817, pctNative: 0.0, pctPacific: 0.0, pctOther: 0.01,
        pluralityGroup: "Asian",
        pctNoHS: 0.30, pctHS: 0.28, pctBachelors: 0.28, pctGraduate: 0.14,
        pctBachelorsOrHigher: 0.422, incomeMedian: 39163, popDensity: 46913,
        avgAge: 50, pctRenter: 0.971, pctOwner: 0.029, dataComplete: true)
}

/// One office×year election result for a precinct (drives the trajectory).
public struct ElectionResult: Codable, Sendable, Identifiable {
    public var id: String { "\(office)-\(year)" }
    public let office: String
    public let year: Int
    public let dem: Int?
    public let rep: Int?
    public let other: Int?
    public let demShare: Double?

    public init(office: String, year: Int, dem: Int?, rep: Int?, other: Int?, demShare: Double?) {
        self.office = office; self.year = year
        self.dem = dem; self.rep = rep; self.other = other; self.demShare = demShare
    }
}

/// Statewide averages, for "vs <state>" context.
public struct Baseline: Codable, Sendable {
    public let scope: String
    public let pctWhite: Double?
    public let pctBlack: Double?
    public let pctHispanic: Double?
    public let pctAsian: Double?
    public let pctBachelorsOrHigher: Double?
    public let incomeMedian: Int?
    public let pctRenter: Double?
    public let avgAge: Double?
    public let leanDemShare: Double?

    public init(scope: String, pctWhite: Double?, pctBlack: Double?, pctHispanic: Double?,
                pctAsian: Double?, pctBachelorsOrHigher: Double?, incomeMedian: Int?,
                pctRenter: Double?, avgAge: Double?, leanDemShare: Double?) {
        self.scope = scope; self.pctWhite = pctWhite; self.pctBlack = pctBlack
        self.pctHispanic = pctHispanic; self.pctAsian = pctAsian
        self.pctBachelorsOrHigher = pctBachelorsOrHigher; self.incomeMedian = incomeMedian
        self.pctRenter = pctRenter; self.avgAge = avgAge; self.leanDemShare = leanDemShare
    }
}
