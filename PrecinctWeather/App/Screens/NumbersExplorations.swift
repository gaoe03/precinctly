import SwiftUI
import PrecinctKit

// By the Numbers: a chart for every measure on one scrolling page, grouped like the card. Each
// bar opens a detail page listing the precincts inside it.

/// A detail page: one measure, optionally filtered to one bar.
struct NumbersDetailSpec: Hashable {
    let metric: Metric
    let bucket: Int?
    var lowestFirst = false
    /// "See precincts" opens on your bar. A tied extreme opens the full ranking instead.
    var opensOnYou = false
}

/// Opens a detail page. A plain button calling this avoids the disclosure chevron a List adds
/// to every NavigationLink row.
private struct OpenNumbersDetailKey: EnvironmentKey {
    static let defaultValue: (NumbersDetailSpec) -> Void = { _ in }
}
extension EnvironmentValues {
    var openNumbersDetail: (NumbersDetailSpec) -> Void {
        get { self[OpenNumbersDetailKey.self] }
        set { self[OpenNumbersDetailKey.self] = newValue }
    }
}

private func placeName(_ r: RankedPrecinct) -> String {
    // "Precinct 1146, Brooklyn": the card's name, without the state the page is already about.
    "\(precinctTitle(r.precinctName, borough: r.borough)), \(areaDisplay(r.borough))"
}

/// Unit-id prefixes for an aggregate region such as the DMV, empty for a plain state.
@MainActor private func regionPrefixes(_ state: String) -> [String] {
    guard let r = coverageRegion(state), r.isAggregate else { return [] }
    return r.jurisdictions.map(\.code)
}

/// Whether the selected precinct belongs to the area the page is showing.
@MainActor private func selectionInScope(_ p: PrecinctProfile?, state: String, county: String?) -> Bool {
    guard let p else { return false }
    let prefixes = regionPrefixes(state)
    if !prefixes.isEmpty { return prefixes.contains { p.unitID.hasPrefix("\($0)-") } }
    return p.state == state && (county == nil || p.borough == county)
}

// MARK: - Charts

/// Five columns with the share of precincts above each. Bars are gray and the bar holding your
/// precinct is ink, so the eye lands on it first. Lean and shift use the party scale instead.
/// Every label slot has a fixed height, so a two-line label never lifts its bar.
struct DistributionChart: View {
    @Environment(\.openNumbersDetail) private var openDetail
    let dist: Distribution
    var height: CGFloat = 76
    var filter: Int? = nil
    var link: ((Int) -> NumbersDetailSpec)? = nil
    var onTap: ((Int) -> Void)? = nil

    /// Party measures use five flat colors, never a blend: solid blue, light blue, gray for the
    /// middle, light red, solid red.
    /// The lean shades are opaque, never see-through: the party color mixed toward white in light
    /// mode and toward a mid gray in dark mode, so they read as a quieter version of the same
    /// color instead of a murky one on black.
    private static func soft(_ share: Double) -> Color {
        let base = UIColor(Palette.lean(share))
        return Color(UIColor { tc in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            let dark = tc.userInterfaceStyle == .dark
            let m: CGFloat = dark ? 0.45 : 1, t: CGFloat = dark ? 0.5 : 0.45
            return UIColor(red: r + (m - r) * t, green: g + (m - g) * t, blue: b + (m - b) * t, alpha: 1)
        })
    }

    static func partyColor(_ i: Int) -> Color {
        switch i {
        case 0: return Palette.dem
        case 1: return soft(0.9)
        case 3: return soft(0.1)
        case 4: return Palette.rep
        default: return Color.primary.opacity(0.35)
        }
    }

    /// Three steps. The selected bar is ink. Your bar, when another bar is selected, is a
    /// darker gray so you can find your way back. Every other bar is pale. With nothing picked,
    /// your bar is the selection. Party charts keep their five colors and fade the same way.
    private var focus: Int? { filter ?? dist.selectedBucket }

    private static let youGray = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.5) : UIColor(white: 0, alpha: 0.42) })
    private static let paleGray = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.2) : UIColor(white: 0, alpha: 0.13) })

    private func color(_ i: Int) -> Color {
        let isFocus = focus == nil || focus == i
        let isYou = dist.selectedBucket == i
        if dist.metric.leanShare(bucket: i) != nil {
            // The five party colors stay fixed. They only fade on the detail page, once a bar is picked.
            guard let filter else { return Self.partyColor(i) }
            return Self.partyColor(i).opacity(filter == i ? 1 : isYou ? 0.6 : 0.3)
        }
        if isFocus && focus != nil { return Color(uiColor: .label) }
        return isYou ? Self.youGray : Self.paleGray
    }

    // Label slots grow with the labels, up to the same xxxLarge cap.
    @ScaledMetric(relativeTo: .caption2) private var scaledSlot: CGFloat = 1
    private var labelScale: CGFloat { min(scaledSlot, 1.6) }

    private func column(_ i: Int, peak: Int, total: Int) -> some View {
        let count = dist.counts[i]
        return VStack(spacing: 5) {
            Text(dist.percentLabel(bucket: i))
                .brandScaledFigure(15, .bold).monospacedDigit()
                .foregroundStyle(focus == nil || focus == i ? Color.primary : Color.secondary)
            Rectangle().fill(color(i))
                .frame(height: max(3, height * CGFloat(count) / CGFloat(peak)))
            VStack(spacing: 4) {
                VStack(spacing: 1) {
                    Text(dist.metric.bucketLabels[i]).font(.bt(.caption2, .semibold))
                    if let details = dist.metric.bucketDetails {
                        Text(details[i]).font(.bt(.caption2)).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.8)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text("You").font(.bt(.caption2, .bold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .opacity(dist.selectedBucket == i ? 1 : 0)
            }
            // Same height under every bar, so labels never lift a bar.
            .frame(height: (dist.metric.bucketDetails == nil ? 50 : 64) * labelScale, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(_ i: Int, total: Int) -> String {
        let pct = Int((Double(dist.counts[i]) / Double(total) * 100).rounded())
        let detail = dist.metric.bucketDetails.map { ", \($0[i])" } ?? ""
        let you = dist.selectedBucket == i ? ", your precinct" : ""
        return "\(dist.metric.bucketLabels[i])\(detail), \(pct) percent of precincts\(you)"
    }

    var body: some View {
        let peak = max(1, dist.counts.max() ?? 1)
        let total = max(1, dist.total)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<dist.counts.count, id: \.self) { i in
                // Every bar is a real button, so VoiceOver can reach each one.
                Button {
                    if let link { openDetail(link(i)) } else { onTap?(i) }
                } label: { column(i, peak: peak, total: total) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(i, total: total))
                .accessibilityAddTraits(filter == i ? .isSelected : [])
                .accessibilityHint("Lists the precincts in this group")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Said instead of an empty chart when no precinct in the area has the measure.
private func noDataNote(_ metric: Metric, scope: String) -> String {
    "No \(metric.title.lowercased()) data for \(scope)."
}

// MARK: - Combined layout

struct NumbersCombined: View {
    @EnvironmentObject var model: LocationModel
    let county: String?
    let scopeName: String

    /// The same four sections as the card, in the same order, with each measure in the section
    /// where the card shows it.
    static let sections: [(String, [Metric])] = [
        ("Politics", [.lean, .shift, .turnout]),
        ("Who lives here", [.largestGroup]),
        ("Money and education", [.income, .college]),
        ("People and housing", [.age, .density, .renters]),
    ]
    private var sections: [(String, [Metric])] { Self.sections }

    var body: some View {
        if let p = model.selection, !selectionInScope(p, state: model.selectedState, county: county) {
            Section {
                Text(outsideNote(p))
                    .font(.bt(.footnote)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
            }
        }
        // Headers are rows, not pinned section headers: a pinned header floated about 20 pt
        // under the top bar and rows showed through the band above it.
        ForEach(sections, id: \.0) { title, metrics in
            Section {
                BrandListHeader(title, size: 19)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
                ForEach(metrics) { m in
                    MetricBlock(metric: m, county: county, scopeName: scopeName, linked: true,
                                ruleAbove: m != metrics.first)
                        .id(m.rawValue)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 18, trailing: 16))
                }
            }
        }
    }

    private func outsideNote(_ p: PrecinctProfile) -> String {
        let place = "\(countyDisplay(p.borough)), \(p.state)"
        if p.state != model.selectedState {
            return "Your selected precinct is in \(place), so it is not marked here. Switch the map to \(stateName(p.state)) to compare it."
        }
        return "Your selected precinct is in \(place), so it is not marked here. Pick \(countyDisplay(p.borough)) or all of \(stateName(p.state)) above to compare it."
    }
}

private struct MetricBlock: View {
    @EnvironmentObject var model: LocationModel
    @Environment(\.openNumbersDetail) private var openDetail
    let metric: Metric
    let county: String?
    let scopeName: String
    var linked = false
    var ruleAbove = false
    @State private var dist: Distribution?
    @State private var highTies = 1
    @State private var lowTies = 1
    @State private var high: RankedPrecinct?
    @State private var low: RankedPrecinct?
    @State private var yearsNote: String?

    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ruleAbove {
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.bottom, 6)
            }
            // At accessibility sizes the link drops under the title instead of squeezing it to
            // one word per line.
            let titleLayout = dts.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            titleLayout {
                Text(metric.question).font(.bt(.headline, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                if !dts.isAccessibilitySize { Spacer(minLength: 8) }
                if linked, (dist?.total ?? 0) > 0 {
                    Button { openDetail(NumbersDetailSpec(metric: metric, bucket: nil, opensOnYou: true)) } label: {
                        HStack(spacing: 3) {
                            Text("See precincts"); Image(systemName: "chevron.right").font(.bt(.caption2, .bold))
                        }
                        .font(.bt(.caption, .semibold)).foregroundStyle(Color(uiColor: .label))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .buttonStyle(.plain)
                }
            }
            if metric == .largestGroup {
                Text("Share of precincts where each group is the largest.").brandNoteStyle()
                    .padding(.top, -6)
            }
            if metric == .turnout, (dist?.total ?? 0) > 0 {
                Text("Votes divided by a Census estimate of eligible adults. Up to 105% counts as 100%. Precincts above 105% are left out.")
                    .brandNoteStyle().fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -6)
            }
            if let yearsNote {
                Text(yearsNote).brandNoteStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -6)
            }
            if let dist, dist.total == 0 {
                Text(noDataNote(metric, scope: scopeName)).brandNoteStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -6)
            } else if let dist {
                DistributionChart(dist: dist,
                                  link: linked ? { NumbersDetailSpec(metric: metric, bucket: $0) } : nil)
                // The extremes are the two ends of the chart, so they sit right under it. The line
                // about your precinct comes last, as the takeaway.
                if metric != .largestGroup, let high, let low {
                    HStack(alignment: .top, spacing: 14) {
                        extreme(metric.extremeTitle(highest: true, value: high.value), high, ties: highTies, lowestFirst: false)
                        Rectangle().fill(Brand.hairline).frame(width: 1).frame(maxHeight: .infinity)
                        extreme(metric.extremeTitle(highest: false, value: low.value), low, ties: lowTies, lowestFirst: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let s = dist.youSentence(place: model.selection.map(precinctHeadline), scope: scopeName, profile: model.selection) {
                    Text(s).font(.bt(.footnote)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(model.selectedState)|\(county ?? "")|\(model.selection?.unitID ?? "")") {
            let prefixes = regionPrefixes(model.selectedState)
            let unit = selectionInScope(model.selection, state: model.selectedState, county: county) ? model.selection?.unitID : nil
            let (metric, state, county, scope) = (metric, model.selectedState, county, scopeName)
            // Eight or so queries per chart. Off the main thread so scrolling never waits on
            // them. The connection is opened FULLMUTEX, the same as for the widget.
            let r = await Task.detached(priority: .userInitiated) { () -> BlockData in
                let db = PrecinctDB.shared
                let dist = db.distribution(metric, state: state, county: county, prefixes: prefixes, selectedUnitID: unit)
                let years = metric == .shift ? MetricBlock.yearsNote(db.shiftYears(state: state, county: county, prefixes: prefixes), scope: scope) : nil
                let high = db.ranked(metric, state: state, county: county, prefixes: prefixes, bucket: nil, ascending: false, limit: 1).first
                let low = db.ranked(metric, state: state, county: county, prefixes: prefixes, bucket: nil, ascending: true, limit: 1).first
                var ht = 1, lt = 1
                if metric != .largestGroup {
                    ht = high?.value.map { db.tieCount(metric, value: $0, state: state, county: county, prefixes: prefixes) } ?? 1
                    lt = low?.value.map { db.tieCount(metric, value: $0, state: state, county: county, prefixes: prefixes) } ?? 1
                }
                return BlockData(dist: dist, yearsNote: years, high: high, low: low, highTies: ht, lowTies: lt)
            }.value
            guard !Task.isCancelled else { return }
            dist = r.dist; yearsNote = r.yearsNote; high = r.high; low = r.low
            highTies = r.highTies; lowTies = r.lowTies
        }
    }

    private struct BlockData: Sendable {
        let dist: Distribution
        let yearsNote: String?
        let high: RankedPrecinct?
        let low: RankedPrecinct?
        let highTies: Int
        let lowTies: Int
    }

    /// "Compares 2020 with 2024." Mixed areas name the common pair and how many precincts use it.
    nonisolated static func yearsNote(_ pairs: [(from: Int, to: Int, count: Int)], scope: String) -> String? {
        guard let top = pairs.first else { return nil }
        let total = pairs.reduce(0) { $0 + $1.count }
        if top.count == total { return "Change in the presidential margin from \(top.from) to \(top.to)." }
        let share = Int((Double(top.count) / Double(total) * 100).rounded(.down))
        // Name the other elections when every other precinct uses the same pair.
        let rest = pairs.count == 2 ? "\(pairs[1].from) to \(pairs[1].to)" : "earlier elections"
        if share >= 99 {
            let others = total - top.count
            return "Change in the presidential margin from \(top.from) to \(top.to) for all but \(others) \(others == 1 ? "precinct" : "precincts") in \(scope)."
        }
        return "Change in the presidential margin from \(top.from) to \(top.to) for \(share)% of precincts in \(scope). The rest use \(rest)."
    }

    /// One end of the chart. A single precinct opens on the map. A tie opens the list of every
    /// precinct that shares the value, since picking one of them would be arbitrary.
    private func extreme(_ title: String, _ r: RankedPrecinct, ties: Int, lowestFirst: Bool) -> some View {
        Button {
            if ties > 1 {
                openDetail(NumbersDetailSpec(metric: metric, bucket: nil, lowestFirst: lowestFirst))
            } else if model.selectByUnitID(r.unitID, fallbackLat: r.lat, fallbackLon: r.lon) {
                model.showFunFacts = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bt(.caption)).foregroundStyle(.secondary)
                // The title already names the direction ("Biggest swing toward D"), so the figure
                // is the bare number.
                Text(r.value.map { metric == .shift ? "\(Int(abs($0).rounded())) points" : metric.format($0) } ?? "")
                    .brandScaledFigure(19, .bold)
                    .foregroundStyle(metric == .lean ? Palette.lean(r.value) : .primary)
                // The chevron is part of the text, so it follows the last word when a name wraps.
                (Text(ties > 1 ? "\(ties.formatted()) precincts tied" : placeName(r))
                 + Text(" \(Image(systemName: "chevron.right"))").font(.bt(.caption2, .bold)))
                    .font(.bt(.caption)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // No box: the same unframed figure as the card's stats. The chevron marks it tappable.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail page: one measure, the precincts behind each bar

struct NumbersDetail: View {
    @Environment(\.dynamicTypeSize) private var dts

    /// The order names the direction in the chart's own terms.
    private func sortLabel(lowest: Bool) -> String {
        switch metric {
        case .lean: lowest ? "Most Republican first" : "Most Democratic first"
        case .shift: lowest ? "Toward R first" : "Toward D first"
        default: lowest ? "Lowest first" : "Highest first"
        }
    }

    private var sortMenu: some View {
        Menu {
            Button { lowestFirst = false } label: {
                if lowestFirst { Text(sortLabel(lowest: false)) } else { Label(sortLabel(lowest: false), systemImage: "checkmark") }
            }
            Button { lowestFirst = true } label: {
                if lowestFirst { Label(sortLabel(lowest: true), systemImage: "checkmark") } else { Text(sortLabel(lowest: true)) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(sortLabel(lowest: lowestFirst))
                Image(systemName: "chevron.down").font(.bt(.caption2))
            }
            .font(.bt(.caption, .semibold))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Brand.chipShape)
        }
        .accessibilityLabel("Sort, currently \(sortLabel(lowest: lowestFirst))")
    }

    /// Rows that print the same value share a rank (5, 5, 7). Nil when every row ties,
    /// because a column of 1s says nothing.
    private var sharedRanks: [Int]? {
        let text = rows.map { $0.value.map { metric.format($0) } ?? "" }
        guard Set(text).count > 1 else { return nil }
        var ranks: [Int] = []
        for i in text.indices { ranks.append(i > 0 && text[i] == text[i - 1] ? ranks[i - 1] : i + 1) }
        return ranks
    }

    @EnvironmentObject var model: LocationModel
    let county: String?
    let scopeName: String
    @State private var metric: Metric
    @State private var filter: Int?
    @State private var dist: Distribution?
    @State private var rows: [RankedPrecinct] = []
    @State private var limit = 40

    init(spec: NumbersDetailSpec, county: String?, scopeName: String) {
        self.county = county; self.scopeName = scopeName
        _metric = State(initialValue: spec.metric)
        _filter = State(initialValue: spec.bucket)
        _lowestFirst = State(initialValue: spec.lowestFirst)
        opensOnYou = spec.opensOnYou
    }
    private let opensOnYou: Bool
    @State private var lowestFirst: Bool
    @State private var openedOnYou = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    MetricTitlePicker(metric: $metric, filter: $filter)
                    if let dist, dist.total == 0 {
                        Text(noDataNote(metric, scope: scopeName)).brandNoteStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let dist {
                        DistributionChart(dist: dist, height: 120, filter: filter, onTap: { i in
                            filter = filter == i ? nil : i
                        })
                        if let s = dist.youSentence(place: model.selection.map(precinctHeadline), scope: scopeName, profile: model.selection) {
                            Text(s).font(.bt(.footnote)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if dist?.total != 0 {
                        Text(filter == nil ? "Tap a bar to list only its precincts." : "Tap the selected bar to list every precinct.")
                            .brandNoteStyle().padding(.top, 6)
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
            }
            Section {
                // The sort chip reaches the other end of any bar, so "under 20%" can start at 0%.
                BrandSectionHeader(title: filter.map { "\(metric.bucketLabels[$0]) precincts" } ?? "All precincts",
                                   stacked: dts.isAccessibilitySize) { sortMenu }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
                let ranks = sharedRanks
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    Button {
                        if model.selectByUnitID(r.unitID, fallbackLat: r.lat, fallbackLon: r.lon) { model.showFunFacts = false }
                    } label: {
                        HStack(spacing: 12) {
                            if let ranks {
                                Text("\(ranks[i])").font(.bt(.subheadline, .semibold)).foregroundStyle(.secondary)
                                    .monospacedDigit().lineLimit(1).fixedSize().frame(minWidth: 30, alignment: .leading)
                            }
                            Text(placeName(r)).font(.bt(.subheadline))
                            Spacer(minLength: 8)
                            Text(metric == .largestGroup
                                 ? "\(r.label ?? "") \(r.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "")"
                                 : r.value.map { metric.format($0) } ?? "")
                                .font(.bt(.subheadline, .bold)).monospacedDigit()
                                .foregroundStyle(rowColor(r.value))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .brandRowRule()
                if rows.count == limit && limit < 200 {
                    Button { limit += 40 } label: {
                        Text("Show 40 more").font(.bt(.subheadline, .semibold)).foregroundStyle(Color(uiColor: .label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .brandList()
        .brandSolidBar()
        .brandCloseButton()
        .navigationTitle(scopeName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metric) { limit = 40; lowestFirst = false }
        .onChange(of: filter) { limit = 40 }
        .onChange(of: lowestFirst) { limit = 40 }
        .task(id: "\(metric.rawValue)|\(filter ?? -1)|\(model.selectedState)|\(county ?? "")|\(limit)|\(lowestFirst)") {
            let prefixes = regionPrefixes(model.selectedState)
            let unit = selectionInScope(model.selection, state: model.selectedState, county: county) ? model.selection?.unitID : nil
            let (metric, state, county, filter, lowestFirst, limit) = (metric, model.selectedState, county, filter, lowestFirst, limit)
            let d = await Task.detached(priority: .userInitiated) {
                PrecinctDB.shared.distribution(metric, state: state, county: county, prefixes: prefixes, selectedUnitID: unit)
            }.value
            guard !Task.isCancelled else { return }
            dist = d
            // "See precincts" opens on your bar, the same focus as the chart you came from.
            if !openedOnYou {
                openedOnYou = true
                if opensOnYou, filter == nil, let you = d.selectedBucket { self.filter = you; return }
            }
            let r = await Task.detached(priority: .userInitiated) {
                PrecinctDB.shared.ranked(metric, state: state, county: county, prefixes: prefixes,
                                         bucket: filter, ascending: lowestFirst, limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            rows = r
        }
    }
}

extension NumbersDetail {
    /// Lean rows use the lean scale. Shift rows use the party they swung toward, so a list that
    /// mixes both directions can be read at a glance. Everything else is ink.
    fileprivate func rowColor(_ v: Double?) -> Color {
        switch metric {
        case .lean: return Palette.lean(v)
        case .shift:
            guard let v, Int(abs(v).rounded()) > 0 else { return .primary }
            return v > 0 ? Palette.dem : Palette.rep
        default: return .primary
        }
    }
}

/// The measure is the page title. Tapping it opens a menu of every measure, grouped the way
/// the main page groups them, the same pattern as the area title.
private struct MetricTitlePicker: View {
    @Binding var metric: Metric
    @Binding var filter: Int?
    private var groups: [(String, [Metric])] { NumbersCombined.sections }
    var body: some View {
        Menu {
            ForEach(groups, id: \.0) { title, metrics in
                Section(title) {
                    ForEach(metrics) { m in
                        Button { metric = m; filter = nil } label: {
                            if m == metric { Label(m.question, systemImage: "checkmark") } else { Text(m.question) }
                        }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.question).brandScaledDisplay(24, .heavy).foregroundStyle(Color(uiColor: .label))
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.down").font(.bt(.headline, .bold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Choose a measure")
    }
}
