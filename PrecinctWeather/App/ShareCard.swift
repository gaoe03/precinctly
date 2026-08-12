import SwiftUI
import UIKit
import CoreLocation
import PrecinctKit

// MARK: - Shareable precinct card
//
// A rendered image of the selected precinct, for sending to someone instead of a screenshot.
// Structure: a real map of the surrounding blocks with the precinct highlighted, then the whole
// profile underneath, so the card answers "where is this" before "what is it like".
//
// Two rules this view exists to hold:
//  1. Fixed geometry. Sizes are raw point values, never Dynamic-Type-scaled (`Font.serifDisplay`
//     scales, `.system(size:)` does not). The recipient's text-size setting must not change an
//     image the sender already sent. `.environment(\.dynamicTypeSize, .large)` pins the rest.
//  2. Fixed light appearance. The card is a print artifact, not a UI surface, so it renders on
//     paper in both modes (`.environment(\.colorScheme, .light)` at render time). Every color
//     here is therefore a literal, not a dynamic UIColor.

struct ShareCard: View {
    let profile: PrecinctProfile
    let trend: [ElectionResult]
    let baseline: Baseline?
    let map: UIImage?

    // Wide enough that a card carrying the whole profile doesn't come out as a thin ribbon:
    // at 340 the finished image was about 1:2.8, which renders tiny in a message thread.
    static let width: CGFloat = 400
    static let mapSize = CGSize(width: 400, height: 224)

    private var lean: Color { Palette.lean(profile.leanDemShare) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 0) {
                place
                headline.padding(.top, 12)
                if let s = profile.leanDemShare { vote(s).padding(.top, 12) }
                if trend.count >= 2 {
                    section("Presidential trajectory") { TrajectoryStrip(trend: trend) }
                }
                if !raceRows.isEmpty {
                    section("Who lives here") { who }
                }
                section("Money and education") { money }
                section("People and housing") { people }
                footer.padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .frame(width: Self.width)
        .background(Paper.stock)
        // Rounded so the shared image reads as a card wherever it lands. The corners are
        // genuinely transparent, which is why the render keeps its alpha channel rather than
        // flattening onto paper: flattening would square the corners straight back off.
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.dynamicTypeSize, .large)
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if let map {
            Image(uiImage: map)
                .resizable()
                .frame(width: Self.mapSize.width, height: Self.mapSize.height)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Paper.rule).frame(height: 1)
                }
        }
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(precinctHeadline(profile))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(countyDisplay(profile.borough)), \(profile.state)")
                .font(.system(size: 12.5))
                .foregroundStyle(Paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: The vote

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.leanShort)
                .font(.system(size: 46, weight: .heavy, design: .serif))
                .foregroundStyle(lean)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let label = profile.leanLabel {
                Text(label + (profile.leanYear.map { " in \($0)" } ?? ""))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lean)
            } else if profile.leanDemShare == nil {
                Text("No election data")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Paper.muted)
            }
        }
    }

    private func vote(_ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TwoPartyBar(demShare: share)
            HStack(spacing: 0) {
                Text("\(Fmt.pct(share)) Dem").foregroundStyle(Palette.dem)
                Spacer(minLength: 8)
                Text("\(Fmt.pct(1 - share)) Rep").foregroundStyle(Palette.rep)
            }
            .font(.system(size: 12, weight: .semibold))
            // The same honesty caveat the sheet and the widgets carry: a handful of ballots can
            // read R+100, so the card never lets the giant number stand alone.
            if let v = profile.leanVotes, v < 100 {
                Text("Based on only \(v) vote\(v == 1 ? "" : "s") cast")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Paper.muted)
            } else if let t = profile.turnoutEst, t <= 1.05 {
                Text("\(Fmt.pct(min(t, 1))) turnout"
                     + (profile.leanYear.map { " in \($0)" } ?? "")
                     + (profile.leanVotes.map { " from \(Fmt.compact($0)) votes" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Paper.muted)
            }
        }
    }

    // MARK: Sections

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Paper.ink)
            Rectangle().fill(Paper.rule).frame(height: 1)
            content()
        }
        .padding(.top, 13)
    }

    private var raceRows: [(label: String, value: Double)] {
        profile.raceBreakdown.filter { $0.value >= 0.02 }
    }

    private var who: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(raceRows.enumerated()), id: \.element.label) { idx, item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink)
                        .frame(width: 74, alignment: .leading)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    GeometryReader { geo in
                        Rectangle().fill(Palette.rankTint(idx))
                            .frame(width: max(3, geo.size.width * min(1, item.value)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 6)
                    Text(Fmt.pct(item.value))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Paper.ink)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            // Race and Hispanic origin are separate Census questions, so these can total over
            // 100%. Saying so is the difference between a card and a misleading card.
            if raceRows.reduce(0.0, { $0 + $1.value }) > 1.001 {
                Text("Census counts race and Hispanic origin separately, so shares can total over 100%.")
                    .font(.system(size: 9))
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var money: some View {
        HStack(alignment: .top, spacing: 12) {
            stat(profile.incomeMedian.map { Fmt.incomeTopCoded($0) }, "Median income",
                 Delta.money(profile.incomeMedian, baseline?.incomeMedian, baseline?.displayName ?? profile.state))
            stat(profile.pctBachelorsOrHigher.map { Fmt.pct($0) }, "College degree",
                 Delta.points(profile.pctBachelorsOrHigher, baseline?.pctBachelorsOrHigher, baseline?.displayName ?? profile.state))
        }
    }

    private var people: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3),
                  alignment: .leading, spacing: 12) {
            stat(profile.popTotal.map { Fmt.compact($0) }, "Population", nil)
            stat(profile.avgAge.map { String(Int($0.rounded())) }, "Median age", nil)
            stat(profile.popDensity.map { "\(Fmt.compact(Int($0)))/mi²" }, "Density", nil)
            stat(profile.pctRenter.map { Fmt.pct($0) }, "Renters", nil)
            stat(profile.pctOwner.map { Fmt.pct($0) }, "Owners", nil)
        }
    }

    private func stat(_ value: String?, _ label: String, _ delta: (String, Bool)?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .serif)).monospacedDigit()
                .foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let delta {
                Text(delta.0)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(delta.1 ? Paper.up : Paper.down)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The wordmark is the one piece of branding on the card, and it was reading as
            // smaller than the stat labels above it. Big enough to be the signature, still
            // quieter than any number.
            Text("Precinctly")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Paper.ink)
            Spacer(minLength: 4)
            Text("\(profile.leanYear.map(String.init) ?? "Latest") presidential vote. 2020 Census and ACS.")
                .font(.system(size: 9))
                .foregroundStyle(Paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// The card stock.
    static let paperStock = Color(red: 0.961, green: 0.953, blue: 0.933)

    /// Fixed print palette. Not dynamic: see the light-appearance rule at the top of this file.
    fileprivate enum Paper {
        static let stock = ShareCard.paperStock
        static let rule  = Color(red: 0.804, green: 0.792, blue: 0.757)
        static let ink   = Color(red: 0.129, green: 0.145, blue: 0.184)
        static let muted = Color(red: 0.416, green: 0.427, blue: 0.459)
        static let up    = Color(red: 0.13, green: 0.45, blue: 0.24)
        static let down  = Color(red: 0.70, green: 0.36, blue: 0.06)
    }
}

/// Compact version of the sheet's trajectory chart. Redrawn rather than reused because the sheet's
/// version is sized by Dynamic Type and a shared image must not be.
private struct TrajectoryStrip: View {
    let trend: [ElectionResult]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top: CGFloat = 13, bottom = h - 24
            let n = max(1, trend.count)
            let slot = w / CGFloat(n)
            let px: (Int) -> CGFloat = { i in slot * (CGFloat(i) + 0.5) }
            let barW = min(34, slot * 0.5)
            let shares = trend.compactMap { $0.demShare }
            let lo0 = shares.min() ?? 0.4, hi0 = shares.max() ?? 0.6
            let pad = max(0.02, (hi0 - lo0) * 0.12)
            let lo = min(0.5, lo0 - pad), hi = max(0.5, hi0 + pad)
            let py: (Double) -> CGFloat = { s in bottom - CGFloat((s - lo) / (hi - lo)) * (bottom - top) }
            ZStack {
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    let yEven = py(0.5), yVal = py(s), up = s >= 0.5
                    UnevenRoundedRectangle(topLeadingRadius: up ? 3 : 0, bottomLeadingRadius: up ? 0 : 3,
                                           bottomTrailingRadius: up ? 0 : 3, topTrailingRadius: up ? 3 : 0)
                        .fill(Palette.lean(s))
                        .frame(width: barW, height: max(2, abs(yVal - yEven)))
                        .position(x: px(i), y: (yEven + yVal) / 2)
                }
                // Drawn over the bars: behind them, a year that only just crosses over reads as a
                // clipped bar instead of a crossing.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: py(0.5)))
                    p.addLine(to: CGPoint(x: w, y: py(0.5)))
                }
                .stroke(ShareCard.Paper.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    let yVal = py(s)
                    Text(margin(s))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Palette.lean(s))
                        .position(x: px(i), y: s >= 0.5 ? max(7, yVal - 8) : min(yVal + 8, h - 18))
                    Text(String(e.year))
                        .font(.system(size: 9.5))
                        .foregroundStyle(ShareCard.Paper.muted)
                        .position(x: px(i), y: h - 5)
                }
            }
        }
        .frame(height: 78)
    }

    private func margin(_ s: Double) -> String {
        let m = Int((abs(s - 0.5) * 200).rounded())
        if m < 1 { return "Even" }
        return (s >= 0.5 ? "D+" : "R+") + "\(m)"
    }
}

// MARK: - Render + share

enum ShareCardRenderer {
    static let scale: CGFloat = 3

    /// Renders at 3x so the card stays crisp when a messaging app scales it up. The map hero is
    /// fetched first because `MKMapSnapshotter` is async and `ImageRenderer` is not.
    @MainActor
    static func image(profile: PrecinctProfile,
                      rings: [[CLLocationCoordinate2D]],
                      trend: [ElectionResult],
                      baseline: Baseline?) async -> UIImage? {
        let map = await ShareCardMap.image(profile: profile, rings: rings,
                                           size: ShareCard.mapSize, scale: scale)
        let renderer = ImageRenderer(content:
            ShareCard(profile: profile, trend: trend, baseline: baseline, map: map)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = scale
        // NOT isOpaque, for two reasons. The card's corners are rounded and must stay
        // transparent, and an opaque backing also paints black wherever the content doesn't
        // reach: ImageRenderer rounds its canvas up past the intrinsic height, which showed as
        // a 2pt black band along the top and bottom of every card.
        renderer.isOpaque = false
        return renderer.uiImage
    }

    /// Writes a named PNG rather than passing a bare UIImage around: the file arrives called
    /// "Precinct 1320, Queens NY.png" instead of the recipient's generic image name, and Save
    /// can reuse the same bytes instead of re-encoding.
    static func write(_ image: UIImage, for profile: PrecinctProfile) -> URL? {
        guard let png = image.pngData() else { return nil }
        let name = "\(precinctHeadline(profile)), \(countyDisplay(profile.borough)) \(profile.state)"
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe.isEmpty ? "Precinct" : safe)
            .appendingPathExtension("png")
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// Top-right button on the expanded panel. It opens the preview screen immediately and lets that
/// screen do the rendering: the map hero is a network fetch, so rendering before presenting would
/// leave the button hanging with nothing on screen.
struct ShareCardButton: View {
    let profile: PrecinctProfile
    let rings: [[CLLocationCoordinate2D]]
    let trend: [ElectionResult]
    let baseline: Baseline?
    @State private var showPreview = false

    var body: some View {
        Button { showPreview = true } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share this precinct")
        .sheet(isPresented: $showPreview) {
            ShareCardPreview(profile: profile, rings: rings, trend: trend, baseline: baseline)
        }
    }
}
