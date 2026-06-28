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
}

/// One-shot location fetch for the widget. `NSWidgetWantsLocation` grants access while the
/// app is authorized, so the widget can resolve the current precinct straight from the
/// bundled DB — no App Group required (that needs a paid account). Coordinates stay on device.
final class WidgetLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: ((CLLocation?) -> Void)?
    func fetch(_ completion: @escaping (CLLocation?) -> Void) {
        if let loc = manager.location { completion(loc); return }   // last known fix
        done = completion
        manager.delegate = self
        manager.requestLocation()
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        done?(locs.last); done = nil
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        done?(nil); done = nil
    }
}

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
    /// Resolve the precinct (+ its shape) at the device's location from the bundled DB; fall back
    /// to the app's cached profile (App Group, if provisioned), else the "open app" placeholder.
    private func resolve(_ completion: @escaping (PrecinctEntry) -> Void) {
        let locator = WidgetLocator()
        locator.fetch { loc in
            _ = locator   // retain until the callback fires
            let profile: PrecinctProfile?
            let rings: [[CLLocationCoordinate2D]]
            if let loc {
                let hit = PrecinctDB.shared.lookup(lon: loc.coordinate.longitude, lat: loc.coordinate.latitude)
                profile = hit?.profile
                rings = hit?.rings ?? []                       // already decoded by lookup
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
                                     shiftPts: shiftPts, shiftSinceYear: sinceYear))
        }
    }
}

// MARK: - Home screen widget (color)

struct PrecinctWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrecinctWidget", provider: PrecinctProvider()) { entry in
            PrecinctHomeView(entry: entry)
                .containerBackground(WidgetColor.mapTone, for: .widget)
        }
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

    /// Faint street-map grid behind the content (the precinct shape lives in its own chip now).
    private func backdrop() -> some View {
        MapGrid().stroke(WidgetColor.gridLine, lineWidth: 1).opacity(0.6).padding(-6)
    }

    /// Small framed "mini-map" of the precinct's own shape, lean-tinted.
    private func precinctChip(_ rings: [[CLLocationCoordinate2D]], _ lean: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(WidgetColor.chipFill)
            PrecinctOutline(rings: rings).fill(lean.opacity(0.22)).padding(5)
            PrecinctOutline(rings: rings).stroke(lean, lineWidth: 1.4).padding(5)
            RoundedRectangle(cornerRadius: 7).strokeBorder(WidgetColor.ink.opacity(0.4), lineWidth: 1)
        }
        .frame(width: 38, height: 38)
    }

    private func small(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return ZStack {
            backdrop()
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.precinctName ?? "Precinct").font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Text("\(countyDisplay(p.borough)), \(p.state)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 2)
                    Image("WidgetPin").resizable().scaledToFit().frame(width: 18, height: 22)
                }
                Spacer(minLength: 1)
                Text(p.leanShort).font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                if let sh = shiftLabel(e.shiftPts, e.shiftSinceYear) {
                    Text(sh).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                if let s = p.leanDemShare { TwoPartyBarW(demShare: s).padding(.vertical, 3) }
                if let top = p.raceBreakdown.first {
                    Text("\(pctStr(top.value)) \(top.label)").font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Text(statsLineA(p)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func medium(_ p: PrecinctProfile, _ e: PrecinctEntry) -> some View {
        let lean = WidgetColor.lean(p.leanDemShare)
        return ZStack {
            backdrop()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 6) {
                        Image("WidgetPin").resizable().scaledToFit().frame(width: 15, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.precinctName ?? "Precinct").font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text("\(countyDisplay(p.borough)), \(p.state)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        if !e.rings.isEmpty { Spacer(minLength: 4); precinctChip(e.rings, lean) }
                    }
                    Spacer(minLength: 2)
                    Text(p.leanShort).font(.system(.title, design: .serif).weight(.heavy))
                        .foregroundStyle(lean).lineLimit(1).minimumScaleFactor(0.6)
                    if let sh = shiftLabel(e.shiftPts, e.shiftSinceYear) {
                        Text(sh).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if let s = p.leanDemShare { TwoPartyBarW(demShare: s).frame(width: 130).padding(.top, 3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statGrid(p)
            }
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

    private func statsLineA(_ p: PrecinctProfile) -> String {
        var parts: [String] = []
        if let inc = p.incomeMedian { parts.append(moneyShort(inc)) }
        if let t = p.turnoutEst { parts.append("\(pctStr(min(t, 1))) turnout") }
        return parts.joined(separator: " · ")
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "mappin.and.ellipse").font(.title2)
            Text("Open Precinct once and allow location").font(.caption)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Hand-drawn-style widget components (static; widgets can't run live filters)

/// Two-party bar: blue (Dem) over red (Rep), capsule-clipped, with a dark ink outline.
private struct TwoPartyBarW: View {
    let demShare: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(WidgetColor.lean(0.12))
                Rectangle().fill(WidgetColor.lean(0.9)).frame(width: max(4, geo.size.width * demShare))
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

/// Faint background grid evoking a street map.
private struct MapGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1..<4 { let x = rect.width * CGFloat(i) / 4; p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: rect.height)) }
        for i in 1..<3 { let y = rect.height * CGFloat(i) / 3; p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: rect.width, y: y)) }
        return p
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
            Gauge(value: p?.leanDemShare ?? 0.5) {
                Text(p?.leanShort ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        default: // accessoryRectangular
            VStack(alignment: .leading, spacing: 1) {
                Text(p?.precinctName ?? p?.borough ?? "Precinct").font(.headline).widgetAccentable().lineLimit(1)
                Text(p.map { "\(countyDisplay($0.borough)), \($0.state)" } ?? "Open Precinct").font(.caption2).lineLimit(1)
                Text("\(p?.leanShort ?? "—")" + (shiftLabel(entry.shiftPts, entry.shiftSinceYear).map { " · \($0)" } ?? "")).font(.caption).lineLimit(1)
                if let p, let top = p.raceBreakdown.first {
                    Text("\(pctStr(top.value)) \(top.label)" + (p.incomeMedian.map { " · \(moneyShort($0))" } ?? ""))
                        .font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inlineText(_ p: PrecinctProfile?) -> String {
        guard let p else { return "Precinct: open app" }
        var parts = [p.leanShort]
        if let top = p.raceBreakdown.first { parts.append("\(pctStr(top.value)) \(top.label)") }
        if let inc = p.incomeMedian { parts.append(moneyShort(inc)) }
        return parts.joined(separator: " · ")
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
    /// Adapts to the widget's light/dark rendering so text (which uses adaptive .primary/.secondary)
    /// always contrasts the paper — fixes white-on-light-paper in dark mode.
    private static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let mapTone  = dynamic((0.93, 0.94, 0.92), (0.11, 0.12, 0.14))   // street-map paper: light ↔ dark slate
    static let gridLine = dynamic((0.82, 0.85, 0.81), (0.28, 0.31, 0.36))
    static let ink      = dynamic((0.16, 0.20, 0.30), (0.82, 0.85, 0.92))   // bar/chip outline: dark ↔ light
    /// Mini-map chip fill: a faint lighter panel over the paper in either mode.
    static let chipFill = Color(UIColor { tc in
        UIColor(white: 1, alpha: tc.userInterfaceStyle == .dark ? 0.12 : 0.6)
    })
}
