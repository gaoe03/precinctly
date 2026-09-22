import WidgetKit
import SwiftUI
import UIKit
import CoreLocation
import PrecinctKit

// MARK: - Timeline

struct PrecinctEntry: TimelineEntry {
    let date: Date
    let profile: PrecinctProfile?
    let trend: [ElectionResult]              // presidential Dem share by year, for the trajectory
    let baseline: Baseline?                  // the area the stats are measured against
    let shiftPts: Int?                       // presidential margin shift, earliest→latest (+ = toward Dem)
    let shiftSinceYear: Int?                 // the earliest year in that span (usually 2016)
    var outOfCoverage = false                // had a fix, but it fell outside covered areas
    /// When the data was actually read. `date` is when WidgetKit should *render* this entry, and
    /// one fetch fans out into several render times, so the two differ. Their gap is the age the
    /// widget reports.
    var fetchedAt = Date()

    /// The same reading, scheduled to draw at a later moment.
    func rendered(at d: Date) -> PrecinctEntry {
        PrecinctEntry(date: d, profile: profile, trend: trend, baseline: baseline,
                      shiftPts: shiftPts, shiftSinceYear: shiftSinceYear,
                      outOfCoverage: outOfCoverage, fetchedAt: fetchedAt)
    }

    static func empty(outOfCoverage: Bool = false) -> PrecinctEntry {
        PrecinctEntry(date: Date(), profile: nil, trend: [], baseline: nil,
                      shiftPts: nil, shiftSinceYear: nil, outOfCoverage: outOfCoverage)
    }
    static var sample: PrecinctEntry {
        PrecinctEntry(date: Date(), profile: .sample, trend: [], baseline: nil,
                      shiftPts: nil, shiftSinceYear: nil)
    }
}

/// `NSWidgetWantsLocation` grants location access while the app is authorized, so the widget
/// resolves the current precinct straight from the bundled DB. No App Group required
/// (that needs a paid account). Coordinates stay on device.
struct PrecinctProvider: TimelineProvider {
    private let locationProvider: () async -> CLLocation?

    init(locationProvider: @escaping () async -> CLLocation? = PrecinctProvider.currentLocation) {
        self.locationProvider = locationProvider
    }

    func placeholder(in context: Context) -> PrecinctEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (PrecinctEntry) -> Void) {
        let sample = PrecinctEntry.sample
        if context.isPreview { completion(sample); return }
        resolve(completion)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PrecinctEntry>) -> Void) {
        resolve { e in
            // Hourly backstop only — the real trigger is NSWidgetWantsLocation (reloads when you
            // move). Data is static per precinct, so a tighter timer would just waste the daily
            // reload budget (WidgetKit allots ~40–70/day, shared with the location reloads).
            //
            // One fetch, several render times, so the "Updated 5m ago" line climbs on its own
            // between reloads. Extra ENTRIES in a single timeline are free — only the reload
            // costs budget — which is why this beats WidgetKit's self-updating `.relative` text
            // style, whose output reads "3 min, 44 sec ago" rather than "3m ago".
            let steps: [TimeInterval] = [0, 120, 300, 600, 1200, 1800, 2700]
            let entries = steps.map { e.rendered(at: e.fetchedAt.addingTimeInterval($0)) }
            completion(Timeline(entries: entries,
                                policy: .after(e.fetchedAt.addingTimeInterval(60 * 60))))
        }
    }
    /// One-shot location for the widget. Async CLLocationUpdate instead of a delegate:
    /// WidgetKit calls providers on background threads with no runloop, where delegate
    /// callbacks may never arrive (widget stuck on the placeholder forever). The timeout
    /// guarantees the timeline always completes. Coordinates stay on device.
    static func currentLocation() async -> CLLocation? {
        let manager = CLLocationManager()
        // Precise Location off fuzzes fixes by kilometers; precincts are a few blocks wide,
        // so better the cache/placeholder than confidently rendering a neighboring precinct.
        guard manager.accuracyAuthorization != .reducedAccuracy else { return nil }
        if let cached = WidgetLocationPolicy.usableLocation(manager.location) { return cached }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = WidgetLocationPolicy.usableLocation(update.location) { return loc }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Resolve the precinct (+ its shape) at the device's location from the bundled DB; fall back
    /// to the app's cached profile (App Group, if provisioned), else the "open app" placeholder.
    func resolve(_ completion: @escaping (PrecinctEntry) -> Void) {
        Task {
            let loc = WidgetLocationPolicy.usableLocation(await locationProvider())
            let profile: PrecinctProfile?
            var outOfCoverage = false
            if let loc {
                let hit = PrecinctDB.shared.lookup(lon: loc.coordinate.longitude, lat: loc.coordinate.latitude)
                profile = hit?.profile
                outOfCoverage = hit == nil                     // located, but not in a covered state
            } else {
                profile = ProfileStore.load()
            }
            guard let p = profile else {
                completion(.empty(outOfCoverage: outOfCoverage)); return
            }
            let trend = PrecinctDB.shared.electionSeries(unitID: p.unitID)
                .filter { $0.office == "president" && $0.demShare != nil }
                .sorted { $0.year < $1.year }
            // Presidential margin shift, earliest available election → latest (the "2016→2024 trend").
            var shiftPts: Int?, sinceYear: Int?
            if let first = trend.first, let last = trend.last, first.year != last.year,
               let a = first.demShare, let b = last.demShare {
                shiftPts = Int(((b - a) * 200).rounded()); sinceYear = first.year
            }
            // Narrowest meaningful area, so the widget says "vs Queens" rather than "vs NY" where
            // the county is worth comparing against. The widget cannot read the app's picker
            // (no App Group on a free account), so it picks the default rather than the choice,
            // and the label always names whichever area it actually used.
            let baseline = PrecinctDB.shared.comparisonAreas(for: p).first
            completion(PrecinctEntry(date: Date(), profile: p, trend: trend, baseline: baseline,
                                     shiftPts: shiftPts, shiftSinceYear: sinceYear,
                                     outOfCoverage: outOfCoverage))
        }
    }
}

// MARK: - Home screen widget (color)

struct PrecinctWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrecinctWidget", provider: PrecinctProvider()) { entry in
            PrecinctHomeView(entry: entry)
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                .containerBackground(WidgetColor.mapTone, for: .widget)
        }
        // Margins are ours so the row rules can run edge to edge.
        .contentMarginsDisabled()
        .configurationDisplayName("Precinctly")
        .description("The political lean and demographics of where you are.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PrecinctHomeView: View {
    @Environment(\.widgetFamily) private var envFamily
    let entry: PrecinctEntry
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        if let p = entry.profile {
            switch family {
            case .systemLarge: large(p, entry)
            case .systemMedium: medium(p, entry)
            default: small(p, entry)
            }
        } else {
            placeholder
        }
    }

    private func placeLine(_ p: PrecinctProfile) -> String {
        "\(precinctHeadline(p)), \(precinctArea(p))"
    }

    /// When this entry was built. A location widget can sit on a stale precinct if the last
    /// reload was hours ago, so medium and large say how long ago they looked. Small has no room.
    ///
    /// Elapsed time rather than a clock reading: it answers "is this still true where I am?"
    /// without any time-zone reasoning. The provider schedules several render times off one
    /// fetch, so this climbs between reloads even though each string is fixed when drawn.
    private func agoText(_ e: PrecinctEntry) -> String {
        let s = max(0, Int(e.date.timeIntervalSince(e.fetchedAt)))
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(s / 60)m ago" }
        return "Updated \(s / 3600)h ago"
    }

    private func updatedView(_ e: PrecinctEntry, size: CGFloat) -> some View {
        Text(agoText(e))
            .font(Brand.textFixed(size, .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// Every reading the layouts draw from, widest first. One list so small, medium and large
    /// report the same facts and differ only in how many of them fit.
    private func stats(_ p: PrecinctProfile, _ base: Baseline?, namesArea: Bool = true) -> [(String, String)] {
        // Same values and labels as the card, so a precinct reads the same everywhere.
        [p.incomeMedian.map { (moneyFull($0), "Median income") },
         p.pctBachelorsOrHigher.map { (pctStr($0), "College degree") },
         p.avgAge.map { (String(Int($0.rounded())), "Median age") },
         p.pctRenter.map { (pctStr($0), "Renters") },
         p.popTotal.map { (compactNum($0), "Population") },
         p.popDensity.map { ("\(Metric.density.format($0))/mi²", "Density") }].compactMap { $0 }
    }

    private func statGrid(_ p: PrecinctProfile, _ e: PrecinctEntry,
                          count: Int, columns: Int,
                          valueSize: CGFloat, labelSize: CGFloat, spacing: CGFloat,
                          namesArea: Bool = true) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .topLeading), count: columns)
        return LazyVGrid(columns: cols, alignment: .leading, spacing: spacing) {
            ForEach(stats(p, e.baseline, namesArea: namesArea).prefix(count), id: \.1) { value, label in
                StatCell(value: value, label: label, valueSize: valueSize, labelSize: labelSize)
            }
        }
    }

    // MARK: Small — the headline and the bar stay; the trajectory gives up its margin labels
    //
    // Both together do not fit at 170pt. Turnout earns its line because nothing else on the
    // widget reports it, and the chart still shows the shape of the last five elections.

    private func small(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            Text(placeLine(p)).font(Brand.textFixed(9, .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer().frame(height: 7)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(p.leanShort).font(Brand.displayFont(26, .heavy))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                if let label = p.leanLabel {
                    Text(label).font(Brand.textFixed(8, .semibold))
                        .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if let s = p.leanDemShare {
                TwoPartyBarW(demShare: s, height: 5).padding(.top, 3)
                HStack(spacing: 0) {
                    Text("\(pctStr(s)) D").foregroundStyle(WidgetColor.dem)
                    Spacer(minLength: 2)
                    if let sub = smallSubline(p, e) {
                        Text(sub).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                    }
                    Text("\(pctStr(1 - s)) R").foregroundStyle(WidgetColor.rep)
                }
                .font(Brand.textFixed(7.5, .semibold)).padding(.top, 2)
            }
            if e.trend.count >= 2 {
                TrajectoryStrip(trend: e.trend, showMargins: false)
                    .frame(height: 32).padding(.top, 4)
            }
            Spacer().frame(height: 8)
            statGrid(p, e, count: 4, columns: 2, valueSize: 11.5, labelSize: 7.5, spacing: 5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Turnout normally, but a precinct decided by a handful of ballots says so instead. Same
    /// honesty rule the sheet and the share card carry.
    private func smallSubline(_ p: PrecinctProfile, _ e: PrecinctEntry) -> String? {
        if let v = p.leanVotes, v < 100 { return "only \(v) vote\(v == 1 ? "" : "s")" }
        if let t = p.turnoutEst, t <= 1.05 { return "\(pctStr(min(t, 1))) turnout" }
        return nil
    }

    // MARK: Medium — lean and history on the left, the stat grid on the right

    private func medium(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(precinctHeadline(p)).font(Brand.textFixed(11, .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(precinctArea(p)).font(Brand.textFixed(9.5, .regular))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if let sub = mediumSubline(p, e) {
                    Text(sub).font(Brand.textFixed(8.5, .regular)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer().frame(height: 12)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.leanShort).font(Brand.displayFont(34, .heavy))
                        .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                    if let label = p.leanLabel, let y = p.leanYear {
                        Text("\(label) in \(String(y))").font(Brand.textFixed(9, .semibold))
                            .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let s = p.leanDemShare {
                        TwoPartyBarW(demShare: s, height: 6).padding(.top, 4)
                        HStack(spacing: 0) {
                            Text("\(pctStr(s)) Dem").foregroundStyle(WidgetColor.dem)
                            Spacer(minLength: 3)
                            Text("\(pctStr(1 - s)) Rep").foregroundStyle(WidgetColor.rep)
                        }
                        .font(Brand.textFixed(8.5, .semibold)).padding(.top, 2)
                    }
                    Spacer(minLength: 2)
                    if e.trend.count >= 2 {
                        TrajectoryStrip(trend: e.trend, showMargins: false).frame(height: 34)
                    }
                }
                .frame(width: 148)
                VStack(alignment: .leading, spacing: 6) {
                    statGrid(p, e, count: 6, columns: 2, valueSize: 13, labelSize: 8.5, spacing: 7)
                    // Shares the race line's row rather than taking one of its own: medium has no
                    // vertical slack left once the trajectory is in.
                    HStack(spacing: 4) {
                        if let top = p.raceBreakdown.first {
                            Text("\(pctStr(top.value)) \(top.label)")
                                .font(Brand.textFixed(8.5, .regular)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 4)
                        updatedView(e, size: 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumSubline(_ p: PrecinctProfile, _ e: PrecinctEntry) -> String? {
        if let v = p.leanVotes, v < 100 { return "only \(v) vote\(v == 1 ? "" : "s") cast" }
        return votesLine(p, compact: compactNum)
    }

    // MARK: Large — the whole profile

    private func large(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(precinctHeadline(p)).font(Brand.textFixed(13, .semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(precinctArea(p)).font(Brand.textFixed(10.5, .regular))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 6)
                updatedView(e, size: 9)
            }
            Spacer().frame(height: 16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.leanShort).font(Brand.displayFont(40, .heavy))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                if let label = p.leanLabel, let y = p.leanYear {
                    Text("\(label) in \(String(y))").font(Brand.textFixed(11, .semibold))
                        .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if let s = p.leanDemShare {
                TwoPartyBarW(demShare: s, height: 7).padding(.top, 5)
                HStack(spacing: 0) {
                    Text("\(pctStr(s)) Dem").foregroundStyle(WidgetColor.dem)
                    Spacer(minLength: 4)
                    if let sub = mediumSubline(p, e) {
                        Text(sub).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                    }
                    Text("\(pctStr(1 - s)) Rep").foregroundStyle(WidgetColor.rep)
                }
                .font(Brand.textFixed(9, .semibold)).padding(.top, 3)
            }
            if e.trend.count >= 2 {
                sectionHead("Politics")
                TrajectoryStrip(trend: e.trend).frame(height: 60)
            }
            let rows = p.raceBreakdown.filter { $0.value >= 0.02 }.prefix(4)
            if !rows.isEmpty {
                sectionHead("Who lives here")
                VStack(spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.element.label) { idx, item in
                        HStack(spacing: 7) {
                            Text(item.label).font(Brand.textFixed(9.5, .regular))
                                .lineLimit(1).fixedSize().frame(width: 66, alignment: .leading)
                            GeometryReader { geo in
                                Rectangle().fill(WidgetColor.rankTint(idx))
                                    .frame(width: max(2, geo.size.width * min(1, item.value)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 5)
                            Text(pctStr(item.value)).font(Brand.textFixed(9.5, .semibold))
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
            // The card's last two sections, in its order and columns.
            sectionHead("Money and education")
            cells([p.incomeMedian.map { (moneyFull($0), "Median income") }, nil,
                   p.pctBachelorsOrHigher.map { (pctStr($0), "College degree") }])
            sectionHead("People and housing")
            cells([p.popTotal.map { (compactNum($0), "Population") },
                   p.avgAge.map { (String(Int($0.rounded())), "Median age") },
                   p.popDensity.map { ("\(Metric.density.format($0))/mi²", "Density") }])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// One row of three stat columns. A nil leaves its column empty, as on the card.
    private func cells(_ items: [(String, String)?]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Group {
                    if let item { StatCell(value: item.0, label: item.1, valueSize: 14, labelSize: 8.5) }
                    else { Color.clear.frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func sectionHead(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.displayFont(10, .semibold))
            // The card's header rule: ink, inside the content margins.
            Rectangle().fill(Brand.ruleInk).frame(height: 1)
        }
        .padding(.top, 8).padding(.bottom, 5)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            BrandMark(size: 24)
            Text(entry.outOfCoverage
                 ? "No precinct here yet. Precinctly covers \(Coverage.abbrList)."
                 : "Open Precinctly and allow precise location").font(.bt(.caption))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}


// MARK: - Widget components

/// Two-party bar: the Democratic share in blue over a red track.
private struct TwoPartyBarW: View {
    let demShare: Double
    var height: CGFloat = 9
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(WidgetColor.rep)
                Rectangle().fill(WidgetColor.dem).frame(width: max(4, geo.size.width * demShare))
            }
        }
        .frame(height: height)
    }
}

/// A value over its label. The unit the stat grids are built from.
private struct StatCell: View {
    let value: String, label: String
    let valueSize: CGFloat, labelSize: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Brand.displayFont(valueSize, .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Brand.textFixed(labelSize, .regular)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presidential margin over time. Same chart as the profile sheet, sized for a widget.
private struct TrajectoryStrip: View {
    let trend: [ElectionResult]
    var showMargins = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // With margin labels on, the plot stops well short of the year row: a year that
            // crosses over puts its label BELOW the axis, and that label needs somewhere to sit
            // that is neither on the dashes nor on the years.
            let top: CGFloat = showMargins ? 11 : 2
            let bottom = h - (showMargins ? 21 : 12)
            let n = max(1, trend.count)
            let slot = w / CGFloat(n)
            let px: (Int) -> CGFloat = { i in slot * (CGFloat(i) + 0.5) }
            let barW = min(26, slot * 0.52)
            let shares = trend.compactMap { $0.demShare }
            let lo0 = shares.min() ?? 0.4, hi0 = shares.max() ?? 0.6
            let pad = max(0.02, (hi0 - lo0) * 0.12)
            let lo = min(0.5, lo0 - pad), hi = max(0.5, hi0 + pad)
            let py: (Double) -> CGFloat = { s in bottom - CGFloat((s - lo) / (hi - lo)) * (bottom - top) }
            ZStack {
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    let yEven = py(0.5), yVal = py(s)
                    Rectangle()
                        .fill(WidgetColor.lean(s))
                        .frame(width: barW, height: max(1.5, abs(yVal - yEven)))
                        .position(x: px(i), y: (yEven + yVal) / 2)
                }
                // Drawn OVER the bars: behind them, a year that only just crosses over reads as
                // a clipped bar instead of a crossing.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: py(0.5)))
                    p.addLine(to: CGPoint(x: w, y: py(0.5)))
                }
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    if showMargins {
                        // Offset from the AXIS, not the bar tip: a barely-crossed year has a 2pt
                        // bar sitting on the line, and a tip-relative label lands on the dashes.
                        // Split out of the .position call: inline, the ternary over two CGFloat
                        // min/max chains blows the type checker's budget.
                        let labelY: CGFloat = marginLabelY(share: s, axis: py(0.5), tip: py(s), height: h)
                        Text(marginLabel(s)).font(Brand.textFixed(7.5, .bold))
                            .foregroundStyle(WidgetColor.lean(s))
                            .position(x: px(i), y: labelY)
                    }
                    Text(String(e.year).suffix(2)).font(Brand.textFixed(8, .regular))
                        .foregroundStyle(.secondary)
                        .position(x: px(i), y: h - 4)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Presidential margin over time: "
                            + trend.map { "\($0.year) \(marginLabel($0.demShare ?? 0.5))" }.joined(separator: ", "))
    }

    private func marginLabel(_ s: Double) -> String {
        let m = Int((abs(s - 0.5) * 200).rounded())
        return m < 1 ? "Even" : (s >= 0.5 ? "D+" : "R+") + "\(m)"
    }

    private func marginLabelY(share: Double, axis: CGFloat, tip: CGFloat, height: CGFloat) -> CGFloat {
        if share >= 0.5 { return max(5, min(axis, tip) - 7) }
        return min(max(axis, tip) + 8, height - 13)
    }
}

// MARK: - Lock screen widget (monochrome / tinted)

struct PrecinctLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrecinctLockWidget", provider: PrecinctProvider()) { entry in
            PrecinctLockView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Precinctly (Lock Screen)")
        .description("Glance at your precinct's lean and top demographic.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct PrecinctLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrecinctEntry

    var body: some View {
        let p = entry.profile
        switch family {
        case .accessoryInline:
            Text(inlineText(p))
        case .accessoryCircular:
            // The lean margin itself, not a capacity ring (which reads as a battery).
            let accessibilityLabel: String = {
                guard let p else { return "No precinct data" }
                return p.leanDemShare == nil ? "No election data" : p.leanShort
            }()
            ZStack {
                AccessoryWidgetBackground()
                Text(p == nil ? "No data" : p?.leanDemShare == nil ? "No election" : p?.leanShort ?? "No data")
                    .font(Brand.textFont(.headline, .bold)).widgetAccentable()
                    .minimumScaleFactor(0.5).lineLimit(1).padding(4)
                    .accessibilityLabel(accessibilityLabel)
            }
        default: // accessoryRectangular
            VStack(alignment: .leading, spacing: 1) {
                Text(p.map(precinctHeadline) ?? "Precinctly").font(.bt(.headline)).widgetAccentable().lineLimit(1)
                Text(p.map { precinctArea($0) }
                     ?? (entry.outOfCoverage ? "No precinct here yet" : "Open Precinctly"))
                    .font(.bt(.caption2)).lineLimit(1)
                Text((p?.leanShort ?? "No precinct data")
                     + (rectSubline(p).map { ", \($0)" } ?? ""))
                    .font(.bt(.caption)).lineLimit(1)
                if let p, let top = p.raceBreakdown.first {
                    Text("\(pctStr(top.value)) \(top.label)" + (p.incomeMedian.map { ", \(moneyShort($0))" } ?? ""))
                        .font(.bt(.caption2)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Same tiny-electorate honesty as the home widget's subline.
    private func rectSubline(_ p: PrecinctProfile?) -> String? {
        if let v = p?.leanVotes, v < 100 { return "only \(v) vote\(v == 1 ? "" : "s")" }
        return shiftLabel(entry.shiftPts, entry.shiftSinceYear)
    }

    private func inlineText(_ p: PrecinctProfile?) -> String {
        guard let p else { return entry.outOfCoverage ? "No precinct here yet" : "Open Precinctly" }
        var parts = [p.leanShort]
        if let top = p.raceBreakdown.first { parts.append("\(pctStr(top.value)) \(top.label)") }
        if let inc = p.incomeMedian { parts.append(moneyShort(inc)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Local helpers (widget keeps PrecinctKit UI-free)

private func pctStr(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func shiftLabel(_ pts: Int?, _ year: Int?) -> String? {
    guard let pts, let year else { return nil }
    if pts == 0 { return "Flat since \(year)" }
    return "\(pts > 0 ? "D+\(pts)" : "R+\(-pts)") since \(year)"
}
private func moneyShort(_ v: Int) -> String {
    if v >= 250001 { return "$250k+" }            // ACS income top-code
    if v >= 1000 { return "$\(Int((Double(v) / 1000).rounded()))k" }
    return "$\(v)"
}
/// The app's compact count (Fmt.compact): one decimal, a trailing ".0" dropped. 2.9k, 20.2M.
private func compactNum(_ n: Int) -> String {
    func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
    if n >= 1_000_000 { return trimmed(Double(n) / 1_000_000) + "M" }
    if n >= 1_000 { return trimmed(Double(n) / 1_000) + "k" }
    return "\(n)"
}
/// The card's income figure: $37,654, or $250k+ at the Census top code.
private func moneyFull(_ v: Int) -> String {
    if v >= 250001 { return "$250k+" }
    return "$" + v.formatted(.number.grouping(.automatic))
}

enum WidgetColor {
    /// The app's lean scale and party anchors.
    static func lean(_ share: Double?) -> Color { Brand.leanColor(share) }
    static var dem: Color { lean(0.9) }
    static var rep: Color { lean(0.1) }
    /// One-hue ramp keyed by rank, the same as the app's race bars: largest group darkest.
    static func rankTint(_ rank: Int) -> Color {
        Brand.rankBase.opacity(max(0.35, 1.0 - Double(rank) * 0.16))
    }
    /// Widget background: the system background, like the app's sheet.
    static let mapTone = Brand.surface
}
