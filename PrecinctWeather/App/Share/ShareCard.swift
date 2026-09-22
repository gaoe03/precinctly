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
//  1. Fixed geometry. Sizes are raw point values (`Brand.textFixed`, `Brand.displayFont`), never
//     Dynamic-Type-scaled. The recipient's text-size setting must not change an image the sender
//     already sent. `.environment(\.dynamicTypeSize, .large)` pins the rest.
//  2. Explicit appearance. The exported card follows the app's resolved light or dark mode with
//     fixed palettes, so its colors do not depend on the renderer's process-wide UIKit traits.

struct ShareCard: View {
    let profile: PrecinctProfile
    let trend: [ElectionResult]
    let baseline: Baseline?
    let map: UIImage?
    let colorScheme: ColorScheme

    // Wide enough that a card carrying the whole profile doesn't come out as a thin ribbon:
    // at 340 the finished image was about 1:2.8, which renders tiny in a message thread.
    static let width: CGFloat = 400
    static let mapSize = CGSize(width: 400, height: 224)

    private var election: ShareCardElectionPresentation {
        ShareCardElectionPresentation(profile: profile, trend: trend)
    }

    private var lean: Color {
        switch election.tint {
        case .neutral: paper.ink
        case .partisan(let share): paper.partisanText(share)
        }
    }

    private var paper: Paper { Paper(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 0) {
                place
                headline.padding(.top, 12)
                if let share = election.voteShare { vote(share).padding(.top, 12) }
                if trend.count >= 2 {
                    section("Politics") {
                        Text("Presidential margin by year")
                            .font(Brand.textFixed(12, .bold))
                            .foregroundStyle(paper.ink)
                        TrajectoryStrip(trend: trend, colorScheme: colorScheme)
                    }
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
        .background(paper.stock)
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
                    Rectangle().fill(paper.rule).frame(height: 1)
                }
        }
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(precinctHeadline(profile))
                .font(Brand.textFixed(16, .semibold))
                .foregroundStyle(paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(precinctArea(profile))
                .font(Brand.textFixed(12.5, .regular))
                .foregroundStyle(paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: The vote

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(election.headline)
                .font(Brand.displayFont(46, .heavy))
                .foregroundStyle(lean)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let detail = election.detail {
                Text(detail)
                    .font(Brand.textFixed(14, .semibold))
                    .foregroundStyle(lean)
            }
        }
    }

    private func vote(_ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TwoPartyBar(demShare: share)
            HStack(spacing: 0) {
                Text("\(Fmt.pct(share)) Dem").foregroundStyle(paper.partisanText(0.9))
                Spacer(minLength: 8)
                Text("\(Fmt.pct(1 - share)) Rep").foregroundStyle(paper.partisanText(0.1))
            }
            .font(Brand.textFixed(12, .semibold))
            // The same honesty caveat the sheet and the widgets carry: a handful of ballots can
            // read R+100, so the card never lets the giant number stand alone.
            if let v = profile.leanVotes, v < 100 {
                Text("Based on only \(v) vote\(v == 1 ? "" : "s") cast")
                    .font(Brand.textFixed(11, .semibold))
                    .foregroundStyle(paper.muted)
            } else if let line = votesLine(profile, compact: Fmt.compact) {
                Text(line)
                    .font(Brand.textFixed(11, .regular))
                    .foregroundStyle(paper.muted)
            }
        }
    }

    // MARK: Sections

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Brand.displayFont(15, .bold))
                .foregroundStyle(paper.ink)
            // Title over a rule, the same header as the card in the app.
            Rectangle().fill(paper.ink.opacity(0.85)).frame(height: 1.5)
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
                        .font(Brand.textFixed(13.5, .regular))
                        .foregroundStyle(paper.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        Rectangle().fill(paper.rankTint(idx))
                            .frame(width: max(3, geo.size.width * min(1, item.value)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 8)
                    Text(Fmt.pct(item.value))
                        .font(Brand.textFixed(13.5, .semibold).monospacedDigit())
                        .foregroundStyle(paper.ink)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            // Race and Hispanic origin are separate Census questions, so these can total over
            // 100%. Saying so is the difference between a card and a misleading card.
            if raceRows.reduce(0.0, { $0 + $1.value }) > 1.001 {
                Text("Census counts race and Hispanic origin separately, so shares can total over 100%.")
                    .font(Brand.textFixed(7.5, .regular))
                    .foregroundStyle(paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Same three columns as People and housing, so College degree lines up with Density.
    private var money: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3),
                  alignment: .leading, spacing: 12) {
            stat(profile.incomeMedian.map { Fmt.incomeTopCoded($0) }, "Median income",
                 Delta.money(profile.incomeMedian, baseline?.incomeMedian, baseline?.readerName ?? profile.state), large: true)
            Color.clear.frame(height: 1)
            stat(profile.pctBachelorsOrHigher.map { Fmt.pct($0) }, "College degree",
                 Delta.points(profile.pctBachelorsOrHigher, baseline?.pctBachelorsOrHigher, baseline?.readerName ?? profile.state), large: true)
        }
    }

    private var people: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3),
                  alignment: .leading, spacing: 12) {
            stat(profile.popTotal.map { Fmt.compact($0) }, "Population", nil)
            stat(profile.avgAge.map { String(Int($0.rounded())) }, "Median age", nil)
            stat(profile.popDensity.map { "\(Metric.density.format($0))/mi²" }, "Density", nil)
            stat(profile.pctRenter.map { Fmt.pct($0) }, "Renters", nil)
            stat(profile.pctOwner.map { Fmt.pct($0) }, "Owners", nil)
        }
    }

    private func stat(_ value: String?, _ label: String, _ delta: (String, Bool)?, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—")
                .font(Brand.figureFont(large ? 22 : 16, .semibold)).monospacedDigit()
                .foregroundStyle(paper.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(Brand.textFixed(11.5, .regular))
                .foregroundStyle(paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let delta {
                Text(delta.0)
                    .font(Brand.textFixed(10, .bold))
                    .foregroundStyle(delta.1 ? paper.up : paper.down)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The wordmark, with the source note under it in the app's note style.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Precinctly")
                .font(Brand.displayFont(17, .semibold))
                .foregroundStyle(paper.ink)
            Text(election.footer)
                .font(Brand.textFixed(8.5, .regular))
                .foregroundStyle(paper.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// Fixed export palettes for light and dark.
    fileprivate struct Paper {
        let colorScheme: ColorScheme
        let stock: Color
        let rule: Color
        let ink: Color
        let muted: Color
        let up: Color
        let down: Color
        let rankBase: Color

        init(colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
            let dark = colorScheme == .dark
            stock = dark ? Color(white: 0.06) : .white
            rule = dark ? Color(white: 1, opacity: 0.22) : Color(white: 0.07, opacity: 0.16)
            ink = dark ? Color(white: 0.95) : Color(white: 0.07)
            muted = dark ? Color(white: 0.64) : Color(white: 0.40)
            up = dark ? Color(red: 0.36, green: 0.76, blue: 0.47) : Color(red: 0.12, green: 0.50, blue: 0.24)
            down = dark ? Color(red: 0.94, green: 0.58, blue: 0.24) : Color(red: 0.70, green: 0.33, blue: 0.0)
            rankBase = dark ? Color(white: 0.72) : Color(white: 0.12)
        }

        func rankTint(_ rank: Int) -> Color {
            rankBase.opacity(max(0.35, 1.0 - Double(rank) * 0.16))
        }

        func partisanText(_ share: Double) -> Color { Palette.lean(share) }
    }
}

/// Compact version of the sheet's trajectory chart. Redrawn rather than reused because the sheet's
/// version is sized by Dynamic Type and a shared image must not be.
private struct TrajectoryStrip: View {
    let trend: [ElectionResult]
    let colorScheme: ColorScheme

    private var paper: ShareCard.Paper { ShareCard.Paper(colorScheme: colorScheme) }

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
                    let yEven = py(0.5), yVal = py(s)
                    Rectangle()
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
                .stroke(paper.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                    let s = e.demShare ?? 0.5
                    let yVal = py(s)
                    Text(margin(s))
                        .font(Brand.textFixed(11, .bold))
                        .foregroundStyle(paper.partisanText(s))
                        .position(x: px(i), y: s >= 0.5 ? max(7, yVal - 8) : min(yVal + 8, h - 18))
                    Text(String(e.year))
                        .font(Brand.textFixed(11, .regular))
                        .foregroundStyle(paper.muted)
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
                      polygons: [PrecinctPolygon],
                      trend: [ElectionResult],
                      baseline: Baseline?,
                      colorScheme: ColorScheme) async -> UIImage? {
        let map = await ShareCardMap.image(profile: profile, polygons: polygons,
                                           size: ShareCard.mapSize, scale: scale,
                                           colorScheme: colorScheme)
        guard !Task.isCancelled else { return nil }
        return render(profile: profile, trend: trend, baseline: baseline, map: map,
                      colorScheme: colorScheme)
    }

    /// Synchronous core used by the async map path and deterministic render tests.
    @MainActor
    static func render(profile: PrecinctProfile,
                       trend: [ElectionResult],
                       baseline: Baseline?,
                       map: UIImage?,
                       colorScheme: ColorScheme) -> UIImage? {
        let renderer = ImageRenderer(content:
            ShareCard(profile: profile, trend: trend, baseline: baseline, map: map,
                      colorScheme: colorScheme)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        guard let rendered = renderer.uiImage,
              let source = rendered.cgImage,
              let bounds = nontransparentBounds(of: source),
              let cropped = source.cropping(to: bounds) else { return nil }
        let content = UIImage(cgImage: cropped, scale: rendered.scale, orientation: .up)

        // ImageRenderer rounds its intrinsic canvas by a fraction of a point. Crop that transparent
        // padding, then flatten onto explicit stock so every exported edge pixel is filled.
        // Rounded presentation belongs to the preview.
        let paper = ShareCard.Paper(colorScheme: colorScheme)
        let format = UIGraphicsImageRendererFormat()
        format.scale = content.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: content.size, format: format).image { context in
            UIColor(paper.stock).setFill()
            context.fill(CGRect(origin: .zero, size: content.size))
            content.draw(in: CGRect(origin: .zero, size: content.size))
        }
    }

    private static func nontransparentBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Writes a named PNG rather than passing a bare UIImage around: the file arrives called
    /// "Precinct 1320, Queens, NY.png" instead of the recipient's generic image name, and Save
    /// can reuse the same bytes instead of re-encoding.
    static func write(_ image: UIImage, for profile: PrecinctProfile) -> URL? {
        guard let png = image.pngData() else { return nil }
        let name = "\(precinctHeadline(profile)), \(precinctArea(profile))"
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe.isEmpty ? "Precinct" : safe)
            .appendingPathExtension("png")
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// Top-right button in the expanded profile hero. It opens the preview screen immediately and lets
/// that screen do the rendering: the map hero is a network fetch, so rendering before presenting
/// would leave the button hanging with nothing on screen.
struct ShareCardButton: View {
    let profile: PrecinctProfile
    let polygons: [PrecinctPolygon]
    let trend: [ElectionResult]
    let baseline: Baseline?
    @State private var showPreview = false

    var body: some View {
        Button { showPreview = true } label: {
            Image(systemName: "square.and.arrow.up")
                .font(Brand.textFixed(15, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Brand.iconShape.fill(Color(.tertiarySystemFill)))
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel("Share this precinct")
        #if DEBUG
        .task {   // screenshot capture
            if ProcessInfo.processInfo.arguments.contains("-openShare") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showPreview = true
            }
        }
        #endif
        .sheet(isPresented: $showPreview) {
            ShareCardPreview(profile: profile, polygons: polygons, trend: trend, baseline: baseline)
        }
    }
}
