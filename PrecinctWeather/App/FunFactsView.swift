import SwiftUI
import PrecinctKit

// MARK: - By the Numbers (dataset superlatives)
//
// A native inset-grouped List. Each category is a Section; min/max pairs that share a `pairKey`
// (lean, shift, edu, age, income) fuse into one RangeRow showing both endpoints; tenure (where
// every winner ties at 100%) becomes a count row that drills into a directory, not a ranked list.
// Standing caveats live behind the nav-bar info button, not inline on every card.

struct FunFactsView: View {
    @EnvironmentObject var model: LocationModel
    @State private var facts: [FunFact] = []
    @State private var overview: ScopeOverview?
    @State private var counties: [String] = []
    @State private var county: String?
    @State private var loading = false
    @State private var leaderboard: LeaderboardSpec?   // pushed drill-in list, if any
    @State private var showAbout = false
    @State private var showCountyPicker = false
    // Cache by scope so re-opening a county (or flipping back to "All") is instant.
    @State private var cache: [String: (facts: [FunFact], overview: ScopeOverview?)] = [:]

    private var scopeKey: String { "\(model.selectedState)|\(county ?? "")" }

    /// Load the current scope's superlatives. Cached scopes return instantly; uncached ones
    /// paint the page first (a quick yield) and then run the ~25 queries, so the open never freezes.
    private func load() async {
        let key = scopeKey, state = model.selectedState, c = county
        if let hit = cache[key] { facts = hit.facts; overview = hit.overview; loading = false; return }
        facts = []; overview = nil; loading = true
        await Task.yield()                            // let the page (menu + spinner) paint first
        guard scopeKey == key else { return }
        let f = PrecinctDB.shared.funFacts(state: state, county: c)
        await Task.yield()
        guard scopeKey == key else { return }
        let o = PrecinctDB.shared.scopeOverview(state: state, county: c)
        guard scopeKey == key else { return }
        facts = f; overview = o; loading = false
        cache[key] = (f, o)
    }

    var body: some View {
        NavigationStack {
            List {
                Section { scopeRow }

                if loading && overview == nil {
                    // A redacted skeleton of the overview grid reads as "loading this layout" rather
                    // than a bare spinner on a page whose shape is already known. Includes a dummy
                    // LeanBar so the section doesn't grow (and shove the page down) when data lands.
                    Section {
                        OverviewGrid(overview: ScopeOverview(precinctCount: 8888, totalPopulation: 8_800_000,
                                                             avgDemShare: 0.5, medianIncome: 88888, leanBuckets: []))
                        LeanBar(buckets: [LeanBucket(label: "Solid Rep", count: 2), LeanBucket(label: "Lean Rep", count: 1),
                                          LeanBucket(label: "Even", count: 1), LeanBucket(label: "Lean Dem", count: 1),
                                          LeanBucket(label: "Solid Dem", count: 2)])
                    }
                    .redacted(reason: .placeholder)
                }

                if let overview {
                    Section {
                        OverviewGrid(overview: overview)
                        if !overview.leanBuckets.isEmpty { LeanBar(buckets: overview.leanBuckets) }
                    }
                }

                ForEach(FactCategory.allCases, id: \.self) { cat in
                    let items = funFactRowItems(facts.filter { $0.category == cat })
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in rowView(item) }
                        } header: {
                            Text(cat.title)
                                .font(.serifDisplay(15, .semibold)).foregroundStyle(.primary).textCase(nil)
                        }
                    }
                }

                if facts.isEmpty && !loading {
                    Text("No ranked precincts in this area.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section {
                    Text("Latest presidential vote. 2020 Census and ACS.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(item: $leaderboard) { spec in
                PrecinctLeaderboard(spec: spec).environmentObject(model)
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAbout) { AboutDataSheet() }
            .sheet(isPresented: $showCountyPicker) {
                CountyPicker(counties: counties, county: $county,
                             stateDisplay: stateName(model.selectedState))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: {
                        Image(systemName: "info.circle").font(.body).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("About this data")
                }
                ToolbarItem(placement: .principal) {
                    Text("By the Numbers").font(.serifDisplay(17, .bold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showFunFacts = false } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task(id: model.selectedState) {
            counties = PrecinctDB.shared.counties(state: model.selectedState)
        }
        .task(id: scopeKey) {
            await load()
        }
    }

    @ViewBuilder
    private func rowView(_ item: RowItem) -> some View {
        switch item {
        case .single(let f):
            FactRow(fact: f, onTap: { tap(f) }, onSeeAll: { leaderboard = $0 })
        case .range(let low, let high, let key):
            RangeRow(low: low, high: high, pairKey: key, onTap: { tap($0) })
        case .tenure(let renter, let owner):
            TenureRow(renter: renter, owner: owner, onTap: { tap($0) }, onSeeAll: { leaderboard = $0 })
        }
    }

    private func tap(_ f: FunFact) {
        // Exact winner by id when we have it: a concave precinct's bbox center can sit in a
        // neighbor (or water), and announcing one precinct then selecting another breaks trust.
        if let uid = f.unitID {
            model.selectByUnitID(uid)
            model.showFunFacts = false
        } else if let la = f.lat, let lo = f.lon {
            model.selectByTap(lat: la, lon: lo)
            model.showFunFacts = false
        }
    }

    // Small states get an inline Menu; past ~30 counties (TX has 254) a flat menu is
    // unnavigable, so the row opens a searchable list instead.
    @ViewBuilder
    private var scopeRow: some View {
        if counties.count > 30 {
            Button { showCountyPicker = true } label: { scopeLabel }
        } else {
            Menu {
                Button { county = nil } label: {
                    if county == nil { Label("All of \(stateName(model.selectedState))", systemImage: "checkmark") }
                    else { Text("All of \(stateName(model.selectedState))") }
                }
                ForEach(counties, id: \.self) { c in
                    Button { county = c } label: {
                        if county == c { Label(countyDisplay(c), systemImage: "checkmark") } else { Text(countyDisplay(c)) }
                    }
                }
            } label: { scopeLabel }
        }
    }

    private var scopeLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
            Text(county.map { countyDisplay($0) } ?? "All of \(stateName(model.selectedState))")
                .fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Searchable county list for big states. Selecting dismisses; the row's checkmark mirrors
/// the Menu variant so both pickers feel like the same control.
private struct CountyPicker: View {
    let counties: [String]
    @Binding var county: String?
    let stateDisplay: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        query.isEmpty ? counties
            : counties.filter { countyDisplay($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    row(nil, title: "All of \(stateDisplay)")
                }
                ForEach(filtered, id: \.self) { c in
                    row(c, title: countyDisplay(c))
                }
            }
            .searchable(text: $query, prompt: "Search counties")
            .navigationTitle("Counties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ value: String?, title: String) -> some View {
        Button {
            county = value
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if county == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

// MARK: - Row grouping (fuse min/max pairs)

enum RowItem: Identifiable {
    case single(FunFact)
    case range(low: FunFact, high: FunFact, key: String)
    case tenure(renter: FunFact, owner: FunFact)
    var id: String {
        switch self {
        case .single(let f):       return "s-\(f.id)"
        case .range(_, _, let k):  return "r-\(k)"
        case .tenure:              return "t-tenure"
        }
    }
}

/// Collapse a category's facts into row items in emit order: a pairKey's two facts fuse into one
/// range (or tenure) row; everything else stays a single row. Unmatched halves fall back to single.
func funFactRowItems(_ facts: [FunFact]) -> [RowItem] {
    var items: [RowItem] = []
    var used = Set<String>()
    for f in facts {
        if used.contains(f.id) { continue }
        guard let pk = f.pairKey,
              let partner = facts.first(where: { $0.pairKey == pk && $0.id != f.id }) else {
            items.append(.single(f)); used.insert(f.id); continue
        }
        used.insert(f.id); used.insert(partner.id)
        if pk == "tenure" {
            let renter = (f.id == "renter") ? f : partner
            let owner  = (f.id == "owner")  ? f : partner
            items.append(.tenure(renter: renter, owner: owner))
        } else {
            let low  = (f.kind == .rangeLow)  ? f : partner
            let high = (f.kind == .rangeHigh) ? f : partner
            items.append(.range(low: low, high: high, key: pk))
        }
    }
    return items
}

private func shortPlace(_ p: String) -> String { p.components(separatedBy: " (").first ?? p }

// MARK: - Components

/// Semantic tint: partisan facts → red/blue; everything else → neutral ink.
func factTint(_ f: FunFact) -> Color {
    guard f.category == .politics else { return .secondary }
    switch f.id {
    case "dem", "shiftD": return Palette.dem
    case "rep", "shiftR": return Palette.rep
    default:              return .secondary
    }
}

private struct OverviewGrid: View {
    let overview: ScopeOverview
    private var leanText: String {
        guard let s = overview.avgDemShare else { return "No data" }
        let m = Int(((s - 0.5) * 200).rounded())
        if m > 0 { return "D+\(m)" }
        if m < 0 { return "R+\(-m)" }
        return "Even"
    }
    var body: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 16) {
            BigStat(value: overview.precinctCount.formatted(), label: "Precincts", delta: nil)
            BigStat(value: overview.totalPopulation.map { Fmt.compact($0) } ?? "No data", label: "Population", delta: nil)
            BigStat(value: leanText, label: "Avg lean", delta: nil, valueColor: Palette.lean(overview.avgDemShare))
            BigStat(value: overview.medianIncome.map { Fmt.incomeTopCoded($0) } ?? "No data", label: "Median income", delta: nil)
        }
        .padding(.vertical, 4)
    }
}

private struct LeanBar: View {
    let buckets: [LeanBucket]
    private func share(_ label: String) -> Double {
        switch label {
        case "Solid Rep": return 0.1
        case "Lean Rep":  return 0.4
        case "Even":      return 0.5
        case "Lean Dem":  return 0.6
        case "Solid Dem": return 0.9
        default:          return 0.5
        }
    }
    private var total: Int { max(1, buckets.reduce(0) { $0 + $1.count }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lean distribution").font(.subheadline.weight(.semibold))
            let ordered = buckets.sorted { share($0.label) > share($1.label) }   // Dem (blue) left -> Rep (red) right
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(ordered) { b in
                        Rectangle().fill(Palette.lean(share(b.label)))
                            .frame(width: geo.size.width * CGFloat(b.count) / CGFloat(total))
                    }
                }
            }
            .frame(height: 14).clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel("Lean distribution: " + ordered.map { "\($0.count) \($0.label)" }.joined(separator: ", "))
            HStack {
                Text("Democratic").font(.caption2).foregroundStyle(Palette.dem)
                Spacer()
                Text("Republican").font(.caption2).foregroundStyle(Palette.rep)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A neutral pill that drills into a fact's full list. "475 precincts" when many tie at the value,
/// otherwise "See all". Never the lean palette.
private struct SeeAllChip: View {
    let tieCount: Int?
    var body: some View {
        HStack(spacing: 3) {
            Text(tieCount.map { "\($0) precincts" } ?? "See all")
            Image(systemName: "chevron.right")
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// One superlative as a List row (no card chrome — the inset section provides the background).
/// The row taps to the winning precinct; the chip (if a crowd) drills into the full list.
/// No leading icon coin: a column of identical gray SF-Symbol circles is Settings-app furniture
/// that carries zero information here (RangeRow proves the layout works without one). The value
/// itself wears the semantic tint where partisanship is the meaning.
private struct FactRow: View {
    let fact: FunFact
    var onTap: () -> Void = {}
    var onSeeAll: (LeaderboardSpec) -> Void = { _ in }
    private var valueTint: Color {
        let t = factTint(fact)
        return t == .secondary ? .primary : t
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let sub = fact.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(fact.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text(fact.value).font(.headline.bold().monospacedDigit())
                    .foregroundStyle(valueTint)
                    .lineLimit(1).fixedSize()
                if let lb = fact.leaderboard {
                    Button { onSeeAll(lb) } label: { SeeAllChip(tieCount: fact.tieCount) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

/// A min↔max pair fused into one row: both endpoints with a track between, showing the span.
private struct RangeRow: View {
    let low: FunFact
    let high: FunFact
    let pairKey: String
    var onTap: (FunFact) -> Void = { _ in }

    private var label: String {
        switch pairKey {
        case "lean":   return "Partisan lean"
        case "shift":  return "Recent shift"
        case "edu":    return "College degree"
        case "age":    return "Median age"
        case "income": return "Household income"
        default:       return ""
        }
    }
    private var partisan: Bool { pairKey == "lean" || pairKey == "shift" }
    private func valueColor(_ f: FunFact) -> Color { partisan ? factTint(f) : .primary }
    // Partisan pairs read as a red→blue spectrum (the color IS the meaning). Neutral metrics
    // (income, age, college) get a low→high intensity ramp — light on the low end, dark on the
    // high — so the track signals which way the variable grows instead of being flat gray.
    private var track: LinearGradient {
        partisan
            ? LinearGradient(colors: [Palette.rep, Palette.lean(0.5), Palette.dem],
                             startPoint: .leading, endPoint: .trailing)
            : LinearGradient(colors: [Palette.rankTint(4), Palette.rankTint(0)],
                             startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.subheadline.weight(.semibold))
            HStack(alignment: .center, spacing: 12) {
                endpoint(low, align: .leading)
                ZStack {
                    Capsule().fill(track).frame(height: 5)
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2.weight(.bold))
                        // White vanishes on the light end of the neutral ramp in light mode;
                        // primary ink reads on both tracks in both schemes.
                        .foregroundStyle(partisan ? Color.white.opacity(0.9) : Color.primary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                endpoint(high, align: .trailing)
            }
        }
        .padding(.vertical, 6)
    }

    private func endpoint(_ f: FunFact, align: HorizontalAlignment) -> some View {
        Button { onTap(f) } label: {
            VStack(alignment: align, spacing: 2) {
                Text(f.value).font(.headline.bold().monospacedDigit()).foregroundStyle(valueColor(f))
                    .lineLimit(1).fixedSize()
                Text(shortPlace(f.place)).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 116, alignment: align == .leading ? .leading : .trailing)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Renters and owners both saturate at 100%, so a range or a ranked list is meaningless. Show the
/// two COUNTS (how many precincts are entirely one or the other), each drilling into a directory.
private struct TenureRow: View {
    let renter: FunFact
    let owner: FunFact
    var onTap: (FunFact) -> Void = { _ in }
    var onSeeAll: (LeaderboardSpec) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Home tenure").font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                stat(renter, noun: "renter")
                Divider().frame(height: 36)
                stat(owner, noun: "owner")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stat(_ f: FunFact, noun: String) -> some View {
        let saturated = f.tieCount != nil
        Button {
            if let lb = f.leaderboard { onSeeAll(lb) } else { onTap(f) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(saturated ? "\(f.tieCount!)" : f.value)
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(.primary)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
                Text(saturated ? "all-\(noun) precincts" : "most \(noun)-occupied")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Methodology

private struct AboutDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Where this comes from") {
                    aboutRow("Votes", "The most recent presidential election, counted by precinct.")
                    aboutRow("People and money", "The 2020 Census and the Census Bureau's American Community Survey, a rolling five-year estimate.")
                }
                Section("Things worth knowing") {
                    aboutRow("Income tops out", "The Census reports household income only up to $250,000, shown here as $250k+, so many well-off precincts tie at that ceiling.")
                    aboutRow("Race can pass 100%", "Race and Hispanic origin are counted separately, so a precinct's race shares can add up to more than 100%.")
                    aboutRow("Small precincts sit out", "Rankings skip very small precincts (under about 500 people or 100 votes), where a single household can swing the number.")
                }
            }
            .navigationTitle("About This Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
    private func aboutRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Drill-in list (ranked, or a directory when every value ties)

private struct PrecinctLeaderboard: View {
    @EnvironmentObject var model: LocationModel
    let spec: LeaderboardSpec
    @State private var rows: [LeaderRow] = []
    @State private var loaded = false

    /// Every displayed value identical (a ceiling/saturated tie) → rank + value columns are noise.
    private var saturated: Bool {
        guard rows.count >= 3 else { return false }
        return Set(rows.map { valueText($0.value) }).count == 1
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                    Button { go(r) } label: { row(idx + 1, r) }.buttonStyle(.plain)
                }
                if loaded && rows.isEmpty {
                    Text("No precincts.").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                if saturated {
                    Text("\(rows.count) precincts tie at \(valueText(rows.first?.value ?? 0))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
                } else {
                    Text(spec.note).font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
            } footer: {
                if rows.count >= 25 { Text("The 25 leaders in this area.") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(spec.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            rows = PrecinctDB.shared.topPrecincts(spec)
            loaded = true
        }
    }

    private func go(_ r: LeaderRow) {
        model.selectByUnitID(r.id)   // exact precinct, not a bbox-center point-in-polygon
        model.showFunFacts = false
    }

    private func valueText(_ v: Double) -> String {
        switch spec.displayKind {
        case .money:   return Fmt.incomeTopCoded(Int(v))
        case .pct:     return Fmt.pct(v)
        case .age:     return "\(Int(v.rounded()))"
        case .density: return "\(Int(v).formatted())/mi²"
        case .lean:
            let m = Int(((v - 0.5) * 200).rounded())
            return m > 0 ? "D+\(m)" : (m < 0 ? "R+\(-m)" : "Even")
        case .shiftPts:
            let p = Int((v * 100).rounded())
            return p >= 0 ? "D+\(p)" : "R+\(-p)"
        }
    }

    private func place(_ r: LeaderRow) -> String {
        let c = countyDisplay(r.borough)
        let n = precinctDisplayName(r.precinctName)
        return n.isEmpty ? "\(c), \(r.state)" : "\(c), \(r.state) (\(n))"
    }

    private func row(_ rank: Int, _ r: LeaderRow) -> some View {
        HStack(spacing: 12) {
            if !saturated {
                Text("\(rank)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            }
            Text(place(r)).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            if !saturated {
                Text(valueText(r.value)).font(.subheadline.bold().monospacedDigit())
                    .lineLimit(1).fixedSize().layoutPriority(1)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

#if DEBUG
/// Debug-only: a non-scrolling, full-height render of the page, for exporting a tall marketing
/// screenshot via ImageRenderer (which can't drive a scrolling List). Mirrors the live components
/// inside manual grouped backgrounds so the export stays close to what users see.
struct ByNumbersExport: View {
    let overview: ScopeOverview?
    let facts: [FunFact]
    let stateDisplay: String          // e.g. "New York"

    private var statusBar: some View {
        ZStack {
            Capsule().fill(.black).frame(width: 125, height: 36)
            HStack(spacing: 0) {
                Text("9:41").font(.system(size: 17, weight: .semibold))
                Image(systemName: "location.north.fill")
                    .font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(45)).padding(.leading, 5)
                Spacer()
                Image(systemName: "cellularbars").font(.system(size: 16))
                Image(systemName: "wifi").font(.system(size: 16)).padding(.leading, 7)
                Image(systemName: "battery.100.bolt").font(.system(size: 16)).foregroundStyle(.green).padding(.leading, 7)
            }
            .padding(.horizontal, 21)
        }
        .foregroundStyle(.black)
        .frame(height: 64)
    }

    private var navBar: some View {
        ZStack {
            Text("By the Numbers").font(.serifDisplay(17, .bold))
            HStack {
                Image(systemName: "info.circle").font(.body).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18)
        }
        .frame(height: 44)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func exportRow(_ item: RowItem) -> some View {
        switch item {
        case .single(let f):                       FactRow(fact: f)
        case .range(let low, let high, let key):   RangeRow(low: low, high: high, pairKey: key)
        case .tenure(let renter, let owner):       TenureRow(renter: renter, owner: owner)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            navBar
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                    Text("All of \(stateDisplay)").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())

                if let overview {
                    group {
                        OverviewGrid(overview: overview)
                        if !overview.leanBuckets.isEmpty { Divider(); LeanBar(buckets: overview.leanBuckets) }
                    }
                }
                ForEach(FactCategory.allCases, id: \.self) { cat in
                    let items = funFactRowItems(facts.filter { $0.category == cat })
                    if !items.isEmpty {
                        Text(cat.title).font(.serifDisplay(15, .semibold)).foregroundStyle(.primary)
                        group {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { Divider() }
                                exportRow(item)
                            }
                        }
                    }
                }
                Text("Latest presidential vote. 2020 Census and ACS.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 44)
        }
        .frame(width: 402, alignment: .leading)
        .background(Color(.systemGroupedBackground))
        .environment(\.colorScheme, .light)
    }
}
#endif
