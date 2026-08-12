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
    var outOfCoverage = false                // had a fix, but it fell outside NY/CA/MA/TX

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
    func placeholder(in context: Context) -> PrecinctEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (PrecinctEntry) -> Void) {
        let sample = PrecinctEntry.sample
        if context.isPreview { completion(sample); return }
        resolve { e in completion(e.profile == nil ? sample : e) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PrecinctEntry>) -> Void) {
        resolve { e in
            // Hourly backstop only — the real trigger is NSWidgetWantsLocation (reloads when you
            // move). Data is static per precinct, so a tighter timer would just waste the daily
            // reload budget (WidgetKit allots ~40–70/day, shared with the location reloads).
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(60 * 60))))
        }
    }
    /// One-shot location for the widget. Async CLLocationUpdate instead of a delegate:
    /// WidgetKit calls providers on background threads with no runloop, where delegate
    /// callbacks may never arrive (widget stuck on the placeholder forever). The timeout
    /// guarantees the timeline always completes. Coordinates stay on device.
    private func currentLocation() async -> CLLocation? {
        let manager = CLLocationManager()
        // Precise Location off fuzzes fixes by kilometers; precincts are a few blocks wide,
        // so better the cache/placeholder than confidently rendering a neighboring precinct.
        guard manager.accuracyAuthorization != .reducedAccuracy else { return nil }
        if let cached = manager.location { return cached }   // last known fix
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = update.location { return loc }
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
    private func resolve(_ completion: @escaping (PrecinctEntry) -> Void) {
        Task {
            let loc = await currentLocation()
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
        // Margins are ours so the ledger rules can run edge to edge like a printed sheet.
        .contentMarginsDisabled()
        .configurationDisplayName("Precinctly")
        .description("The political lean and demographics of where you are.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PrecinctHomeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrecinctEntry

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

    /// Ledger rule: a hairline that runs edge to edge (margins are disabled at the config
    /// level, so the negative padding reaches the widget's true edges).
    private func ledgerRule(inset: CGFloat = -20) -> some View {
        Rectangle().fill(WidgetColor.rule).frame(height: 1).padding(.horizontal, inset)
    }

    private func placeLine(_ p: PrecinctProfile) -> String {
        "\(precinctHeadline(p)), \(countyDisplay(p.borough)) \(p.state)"
    }

    /// Every reading the layouts draw from, widest first. One list so small, medium and large
    /// report the same facts and differ only in how many of them fit.
    /// `namesArea` false where the cell is too narrow to hold "Income vs Orange" without
    /// truncating, in which case the caller names the area somewhere with room.
    private func stats(_ p: PrecinctProfile, _ base: Baseline?, namesArea: Bool = true) -> [(String, String)] {
        [p.incomeMedian.map { (moneyShort($0), (namesArea ? base.map { "Income vs \($0.displayName)" } : nil) ?? "Income") },
         p.pctBachelorsOrHigher.map { (pctStr($0), "College") },
         p.avgAge.map { (String(Int($0.rounded())), "Median age") },
         p.pctRenter.map { (pctStr($0), "Renters") },
         p.popTotal.map { (compactNum($0), "People") },
         p.popDensity.map { ("\(compactNum(Int($0)))/mi²", "Density") }].compactMap { $0 }
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
            Text(placeLine(p)).font(.system(size: 9, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
            ledgerRule().padding(.top, 3).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(p.leanShort).font(.system(size: 26, weight: .heavy, design: .serif))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                if let label = p.leanLabel {
                    Text(label).font(.system(size: 8, weight: .semibold))
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
                .font(.system(size: 7.5, weight: .semibold)).padding(.top, 2)
            }
            if e.trend.count >= 2 {
                TrajectoryStrip(trend: e.trend, showMargins: false)
                    .frame(height: 32).padding(.top, 4)
            }
            ledgerRule().padding(.top, 2).padding(.bottom, 5)
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
                Text(precinctHeadline(p)).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(countyDisplay(p.borough)), \(p.state)").font(.system(size: 9.5))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if let sub = mediumSubline(p, e) {
                    Text(sub).font(.system(size: 8.5)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            ledgerRule().padding(.vertical, 6)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.leanShort).font(.system(size: 34, weight: .heavy, design: .serif))
                        .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                    if let label = p.leanLabel, let y = p.leanYear {
                        Text("\(label) in \(String(y))").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let s = p.leanDemShare {
                        TwoPartyBarW(demShare: s, height: 6).padding(.top, 4)
                        HStack(spacing: 0) {
                            Text("\(pctStr(s)) Dem").foregroundStyle(WidgetColor.dem)
                            Spacer(minLength: 3)
                            Text("\(pctStr(1 - s)) Rep").foregroundStyle(WidgetColor.rep)
                        }
                        .font(.system(size: 8.5, weight: .semibold)).padding(.top, 2)
                    }
                    Spacer(minLength: 2)
                    if e.trend.count >= 2 {
                        TrajectoryStrip(trend: e.trend, showMargins: false).frame(height: 34)
                    }
                }
                .frame(width: 148)
                VStack(alignment: .leading, spacing: 6) {
                    statGrid(p, e, count: 6, columns: 2, valueSize: 13, labelSize: 8.5, spacing: 7)
                    if let top = p.raceBreakdown.first {
                        Text("\(pctStr(top.value)) \(top.label)")
                            .font(.system(size: 8.5)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumSubline(_ p: PrecinctProfile, _ e: PrecinctEntry) -> String? {
        if let v = p.leanVotes, v < 100 { return "only \(v) vote\(v == 1 ? "" : "s") cast" }
        if let t = p.turnoutEst, t <= 1.05, let v = p.leanVotes {
            return "\(pctStr(min(t, 1))) turnout from \(compactNum(v)) votes"
        }
        return nil
    }

    // MARK: Large — the whole profile

    private func large(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            Text(precinctHeadline(p)).font(.system(size: 13, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(countyDisplay(p.borough)), \(p.state)").font(.system(size: 10.5))
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            ledgerRule().padding(.vertical, 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.leanShort).font(.system(size: 40, weight: .heavy, design: .serif))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.5)
                if let label = p.leanLabel, let y = p.leanYear {
                    Text("\(label) in \(String(y))").font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 9, weight: .semibold)).padding(.top, 3)
            }
            if e.trend.count >= 2 {
                sectionHead("Presidential trajectory")
                TrajectoryStrip(trend: e.trend).frame(height: 60)
            }
            let rows = p.raceBreakdown.filter { $0.value >= 0.02 }.prefix(4)
            if !rows.isEmpty {
                sectionHead("Who lives here")
                VStack(spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.element.label) { idx, item in
                        HStack(spacing: 7) {
                            Text(item.label).font(.system(size: 9.5))
                                .frame(width: 62, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
                            GeometryReader { geo in
                                Rectangle().fill(WidgetColor.rankTint(idx))
                                    .frame(width: max(2, geo.size.width * min(1, item.value)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 5)
                            Text(pctStr(item.value)).font(.system(size: 9.5, weight: .semibold))
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
            sectionHead(e.baseline.map { "The numbers, vs \($0.displayName)" } ?? "The numbers")
            statGrid(p, e, count: 6, columns: 3, valueSize: 14, labelSize: 8.5, spacing: 8,
                     namesArea: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func sectionHead(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .serif))
            ledgerRule()
        }
        .padding(.top, 8).padding(.bottom, 5)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image("WidgetPin").resizable().scaledToFit().frame(width: 20, height: 24)
            Text(entry.outOfCoverage
                 ? "No precinct here yet. Precinctly covers \(Coverage.abbrList)."
                 : "Open Precinctly and allow precise location").font(.caption)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}


// MARK: - Hand-drawn-style widget components (static; widgets can't run live filters)

/// Two-party bar: blue (Dem) over red (Rep), capsule-clipped, with a dark ink outline.
private struct TwoPartyBarW: View {
    let demShare: Double
    var height: CGFloat = 9
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(WidgetColor.rep)
                Rectangle().fill(WidgetColor.dem).frame(width: max(4, geo.size.width * demShare))
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(WidgetColor.ink, lineWidth: height >= 7 ? 1.2 : 0.8))
        }
        .frame(height: height)
    }
}

/// value over label, serif number. The unit the stat grids are built from.
private struct StatCell: View {
    let value: String, label: String
    let valueSize: CGFloat, labelSize: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: valueSize, weight: .semibold, design: .serif))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: labelSize)).foregroundStyle(.secondary)
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
                    let yEven = py(0.5), yVal = py(s), up = s >= 0.5
                    UnevenRoundedRectangle(topLeadingRadius: up ? 2 : 0, bottomLeadingRadius: up ? 0 : 2,
                                           bottomTrailingRadius: up ? 0 : 2, topTrailingRadius: up ? 2 : 0)
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
                .stroke(WidgetColor.rule, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    if showMargins {
                        // Offset from the AXIS, not the bar tip: a barely-crossed year has a 2pt
                        // bar sitting on the line, and a tip-relative label lands on the dashes.
                        // Split out of the .position call: inline, the ternary over two CGFloat
                        // min/max chains blows the type checker's budget.
                        let labelY: CGFloat = marginLabelY(share: s, axis: py(0.5), tip: py(s), height: h)
                        Text(marginLabel(s)).font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(WidgetColor.lean(s))
                            .position(x: px(i), y: labelY)
                    }
                    Text(String(e.year).suffix(2)).font(.system(size: 8))
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
            ZStack {
                AccessoryWidgetBackground()
                Text(p?.leanShort ?? "—")
                    .font(.system(.headline, design: .serif)).widgetAccentable()
                    .minimumScaleFactor(0.5).lineLimit(1).padding(4)
            }
        default: // accessoryRectangular
            VStack(alignment: .leading, spacing: 1) {
                Text(p.map(precinctHeadline) ?? "Precinctly").font(.headline).widgetAccentable().lineLimit(1)
                Text(p.map { "\(countyDisplay($0.borough)), \($0.state)" }
                     ?? (entry.outOfCoverage ? "No precinct here yet" : "Open Precinctly"))
                    .font(.caption2).lineLimit(1)
                Text("\(p?.leanShort ?? "—")" + (rectSubline(p).map { ", \($0)" } ?? "")).font(.caption).lineLimit(1)
                if let p, let top = p.raceBreakdown.first {
                    Text("\(pctStr(top.value)) \(top.label)" + (p.incomeMedian.map { ", \(moneyShort($0))" } ?? ""))
                        .font(.caption2).lineLimit(1)
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
private func compactNum(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
    return "\(n)"
}

private enum WidgetColor {
    private static func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }
    /// Matches the app's Palette.lean diverging ramp (red ↔ purple ↔ blue).
    static func lean(_ share: Double?) -> Color {
        guard let s = share else { return .gray }
        let red = (0.85, 0.16, 0.16), purple = (0.55, 0.25, 0.7), blue = (0.13, 0.4, 0.9)
        let t = max(0, min(1, s))
        return t >= 0.5 ? lerp(purple, blue, (t - 0.5) * 2) : lerp(red, purple, t * 2)
    }
    /// Party anchors, same values as the app's Palette.dem/.rep.
    static let dem = lean(0.9)
    static let rep = lean(0.1)
    /// Restrained single-hue ramp keyed by rank, mirroring the app's Palette.rankTint: largest
    /// group darkest. Lighter base in dark mode so the low ranks stay visible.
    static func rankTint(_ rank: Int) -> Color {
        let base = Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.62, green: 0.66, blue: 0.82, alpha: 1)
                : UIColor(red: 0.36, green: 0.40, blue: 0.58, alpha: 1)
        })
        return base.opacity(max(0.35, 1.0 - Double(rank) * 0.16))
    }
    /// Adapts to the widget's light/dark rendering so text (which uses adaptive .primary/.secondary)
    /// always contrasts the paper — fixes white-on-light-paper in dark mode.
    private static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let mapTone  = dynamic((0.93, 0.94, 0.92), (0.11, 0.12, 0.14))   // street-map paper: light ↔ dark slate
    static let rule     = dynamic((0.80, 0.83, 0.78), (0.27, 0.31, 0.35))   // ledger hairlines between row groups
    static let ink      = dynamic((0.16, 0.20, 0.30), (0.82, 0.85, 0.92))   // bar/chip outline: dark ↔ light
    /// Mini-map chip fill: a faint lighter panel over the paper in either mode.
    static let chipFill = Color(UIColor { tc in
        UIColor(white: 1, alpha: tc.userInterfaceStyle == .dark ? 0.12 : 0.6)
    })
}
