import WidgetKit
import SwiftUI
import UIKit
import CoreLocation
import PrecinctKit

// MARK: - Timeline

struct PrecinctEntry: TimelineEntry {
    let date: Date
    let profile: PrecinctProfile?
    let rings: [[CLLocationCoordinate2D]]   // the precinct's shape, for the mini-map chip
    let shiftPts: Int?                       // presidential margin shift, earliest→latest (+ = toward Dem)
    let shiftSinceYear: Int?                 // the earliest year in that span (usually 2016)
    var outOfCoverage = false                // had a fix, but it fell outside NY/CA/MA/TX
}

/// `NSWidgetWantsLocation` grants location access while the app is authorized, so the widget
/// resolves the current precinct straight from the bundled DB. No App Group required
/// (that needs a paid account). Coordinates stay on device.
struct PrecinctProvider: TimelineProvider {
    func placeholder(in context: Context) -> PrecinctEntry {
        PrecinctEntry(date: Date(), profile: .sample, rings: [], shiftPts: nil, shiftSinceYear: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (PrecinctEntry) -> Void) {
        let sample = PrecinctEntry(date: Date(), profile: .sample, rings: [], shiftPts: nil, shiftSinceYear: nil)
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
            let rings: [[CLLocationCoordinate2D]]
            var outOfCoverage = false
            if let loc {
                let hit = PrecinctDB.shared.lookup(lon: loc.coordinate.longitude, lat: loc.coordinate.latitude)
                profile = hit?.profile
                rings = hit?.rings ?? []                       // already decoded by lookup
                outOfCoverage = hit == nil                     // located, but not in a covered state
            } else if let cached = ProfileStore.load() {
                profile = cached
                rings = PrecinctDB.shared.exteriorRings(unitID: cached.unitID)
            } else {
                profile = nil
                rings = []
            }
            // Presidential margin shift, earliest available election → latest (the "2016→2024 trend").
            var shiftPts: Int?, sinceYear: Int?
            if let p = profile {
                let series = PrecinctDB.shared.electionSeries(unitID: p.unitID)
                    .filter { $0.office == "president" && $0.demShare != nil }
                    .sorted { $0.year < $1.year }
                if let first = series.first, let last = series.last, first.year != last.year,
                   let a = first.demShare, let b = last.demShare {
                    shiftPts = Int(((b - a) * 200).rounded()); sinceYear = first.year
                }
            }
            completion(PrecinctEntry(date: Date(), profile: profile, rings: rings,
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
                .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
                .containerBackground(WidgetColor.mapTone, for: .widget)
        }
        // Margins are ours so the ledger rules can run edge to edge like a printed sheet.
        .contentMarginsDisabled()
        .configurationDisplayName("Precinct")
        .description("The political lean and demographics of where you are.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PrecinctHomeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrecinctEntry

    var body: some View {
        if let p = entry.profile {
            switch family {
            case .systemMedium: medium(p, entry)
            default: small(p, entry)
            }
        } else {
            placeholder
        }
    }

    /// Ledger rule: a hairline that runs edge to edge (margins are disabled at the config
    /// level, so the negative padding reaches the widget's true edges).
    private func ledgerRule() -> some View {
        Rectangle().fill(WidgetColor.rule).frame(height: 1).padding(.horizontal, -15)
    }

    /// Small framed "mini-map" of the precinct's own shape, lean-tinted.
    private func precinctChip(_ rings: [[CLLocationCoordinate2D]], _ lean: Color, size: CGFloat = 38) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(WidgetColor.chipFill)
            PrecinctOutline(rings: rings).fill(lean.opacity(0.22)).padding(5)
            PrecinctOutline(rings: rings).stroke(lean, lineWidth: 1.4).padding(5)
            RoundedRectangle(cornerRadius: 7).strokeBorder(WidgetColor.ink.opacity(0.4), lineWidth: 1)
        }
        .frame(width: size, height: size)
    }

    // "Ledger and chip": the old free-floating map grid never lined up with the text, so the
    // paper is ruled instead — hairlines exactly between the row groups — and the precinct's
    // real shape sits in a framed chip beside the header.
    private func small(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(precinctTitle(p)).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(countyDisplay(p.borough)), \(p.state)").font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                if !e.rings.isEmpty { precinctChip(e.rings, lean, size: 34) }
            }
            ledgerRule().padding(.vertical, 7)
            HStack(alignment: .center, spacing: 8) {
                Text(p.leanShort).font(.system(size: 29, weight: .heavy, design: .serif))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                if let sh = subline(p, e) {
                    Text(sh).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
            ledgerRule().padding(.vertical, 7)
            if let s = p.leanDemShare { TwoPartyBarW(demShare: s) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let top = p.raceBreakdown.first {
                    Text("\(pctStr(top.value)) \(top.label)").font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                if let inc = p.incomeMedian {
                    Text("\(moneyShort(inc)) income").font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(precinctTitle(p)).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(countyDisplay(p.borough)), \(p.state)").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                if !e.rings.isEmpty { precinctChip(e.rings, lean, size: 36) }
            }
            ledgerRule().padding(.vertical, 6)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(p.leanShort).font(.system(size: 33, weight: .heavy, design: .serif))
                            .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                        if let sh = subline(p, e) {
                            Text(sh).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 2)
                    if let s = p.leanDemShare { TwoPartyBarW(demShare: s).frame(width: 150) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statGrid(p)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func statGrid(_ p: PrecinctProfile) -> some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            if let top = p.raceBreakdown.first { miniStat(top.label, pctStr(top.value)) }
            if let inc = p.incomeMedian { miniStat("Income", moneyShort(inc)) }
            if let ba = p.pctBachelorsOrHigher { miniStat("College", pctStr(ba)) }
            if let age = p.avgAge { miniStat("Median age", "\(Int(age.rounded()))") }
            if let r = p.pctRenter { miniStat("Renters", pctStr(r)) }
            if let pop = p.popTotal { miniStat("People", compactNum(pop)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// The line under the big lean number: a shift like "D+6 since 2016", except in
    /// tiny-electorate precincts where both the lean and the shift rest on a handful of
    /// ballots; say that instead. (100 matches By-the-Numbers' vote floor.)
    private func subline(_ p: PrecinctProfile, _ e: PrecinctEntry) -> String? {
        if let v = p.leanVotes, v < 100 { return "Only \(v) vote\(v == 1 ? "" : "s") cast" }
        return shiftLabel(e.shiftPts, e.shiftSinceYear)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image("WidgetPin").resizable().scaledToFit().frame(width: 20, height: 24)
            Text(entry.outOfCoverage
                 ? "No precinct here yet. Precinct covers \(Coverage.abbrList)."
                 : "Open Precinct and allow precise location").font(.caption)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

/// CA precinct names are bare SOS ids ("7602", "1290023A"); prefix those so the widget doesn't
/// title itself with a naked number. NY ("AD 75 ED 14") and MA ("...Precinct 1") already read fine.
/// Zero-padded ids ("000363") are stripped first so titles read "Precinct 363".
private func precinctTitle(_ p: PrecinctProfile) -> String {
    guard let raw = p.precinctName, !raw.isEmpty else { return "Precinct" }
    let n = precinctDisplayName(raw)
    if n.localizedCaseInsensitiveContains("precinct") { return n }
    if let f = n.first, f.isNumber, !n.contains(" ") { return "Precinct \(n)" }
    return n
}

// MARK: - Hand-drawn-style widget components (static; widgets can't run live filters)

/// Two-party bar: blue (Dem) over red (Rep), capsule-clipped, with a dark ink outline.
private struct TwoPartyBarW: View {
    let demShare: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(WidgetColor.rep)
                Rectangle().fill(WidgetColor.dem).frame(width: max(4, geo.size.width * demShare))
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(WidgetColor.ink, lineWidth: 1.2))
        }
        .frame(height: 9)
    }
}

/// The selected precinct's polygon(s), normalized into the view's rect (aspect-fit, y-flipped).
private struct PrecinctOutline: Shape {
    let rings: [[CLLocationCoordinate2D]]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !rings.isEmpty else { return path }
        var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        for ring in rings { for c in ring {
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
        }}
        let w = maxLon - minLon, h = maxLat - minLat
        guard w > 0, h > 0 else { return path }
        let scale = min(rect.width / w, rect.height / h)
        let ox = rect.midX - (w * scale) / 2, oy = rect.midY - (h * scale) / 2
        for ring in rings where ring.count > 2 {
            for (i, c) in ring.enumerated() {
                let pt = CGPoint(x: ox + (c.longitude - minLon) * scale,
                                 y: oy + (maxLat - c.latitude) * scale)   // flip: north = up
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Lock screen widget (monochrome / tinted)

struct PrecinctLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrecinctLockWidget", provider: PrecinctProvider()) { entry in
            PrecinctLockView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Precinct (Lock Screen)")
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
                Text(p.map(precinctTitle) ?? "Precinct").font(.headline).widgetAccentable().lineLimit(1)
                Text(p.map { "\(countyDisplay($0.borough)), \($0.state)" }
                     ?? (entry.outOfCoverage ? "No precinct here yet" : "Open Precinct"))
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
        guard let p else { return entry.outOfCoverage ? "No precinct here yet" : "Open Precinct" }
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
