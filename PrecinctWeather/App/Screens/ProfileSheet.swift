import SwiftUI
import UIKit
import PrecinctKit

// MARK: - Bottom panel (custom flush-to-edge card)
//
// Replaces the system `.sheet`: on iOS 26 a partial-detent sheet floats inset from the screen
// edges (rounded all around, map visible underneath). This panel is pinned flush to the bottom,
// full-width, with two heights (peek ↔ full) toggled by tapping or dragging the handle. The
// uncovered map stays tappable for free, which also drops the old presentationBackgroundInteraction.

struct BottomPanel: View {
    @EnvironmentObject var model: LocationModel
    @Binding var expanded: Bool

    static let peekHeight: CGFloat = 190
    /// Peek grows at accessibility text sizes so the hero (including the low-vote caveat,
    /// the line the design exists to protect) stays visible instead of clipping at 190pt.
    static func peekHeight(for dts: DynamicTypeSize) -> CGFloat {
        dts.isAccessibilitySize ? 276 : peekHeight
    }
    // Single source of truth for the live drag height; nil at rest (height follows `expanded`).
    // Using @State (not @GestureState) so the release can clear it together with `expanded` in one
    // animated transaction — otherwise @GestureState's auto-reset fires in a separate frame and the
    // card jumps to its old size before springing to the new one.
    @State private var dragHeight: CGFloat? = nil
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dts
    private var spring: Animation { .spring(response: 0.34, dampingFraction: 0.86) }
    // One prepared generator (matching LocationModel's), not a fresh unprepared one per snap.
    private static let snapHaptic: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g
    }()
    private func snap() { if hapticsEnabled { Self.snapHaptic.impactOccurred() } }

    var body: some View {
        GeometryReader { geo in
            let peekH = Self.peekHeight(for: dts)
            let fullH = max(peekH, geo.size.height)
            let restH = expanded ? fullH : peekH
            let height = dragHeight ?? restH
            VStack(spacing: 0) {
                handle(peekH: peekH, fullH: fullH)
                // Reveal the full profile as soon as the card grows past peek (not only at the end
                // of the drag), so expanding fills in continuously instead of staying blank then
                // popping everything in at once.
                ProfileContent(showContent: height > peekH + 2, scrolls: expanded)
                    // At peek the whole card (not just the handle) taps/drags to expand, matching
                    // how every system sheet behaves. A clear catcher (only present at peek, where
                    // the content is the non-interactive hero) keeps the ScrollView identity stable.
                    // At accessibility sizes the catcher steps aside so the hero can scroll at peek
                    // (the handle still expands); otherwise oversized text would clip with no recourse.
                    .overlay {
                        if !expanded && !dts.isAccessibilitySize {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { snap(); withAnimation(spring) { expanded = true } }
                                .gesture(resizeDrag(peekH: peekH, fullH: fullH))
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .background {
                // Material extended down through the home-indicator strip via negative padding
                // (NOT ignoresSafeArea, which makes the greedy shape fill the whole screen) so the
                // card sits flush to the bottom edge — no map showing underneath.
                // Opaque, not material: the frosted panel live-blurred the map (tint polygons
                // included) on every frame of a drag, which is what made resizing feel heavy
                // in polygon-dense counties. A solid card costs nothing to move.
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
                    .padding(.bottom, -geo.safeAreaInsets.bottom)
            }
            .overlay(alignment: .top) {
                // Invisible grab strip: the visible handle stays a 5pt capsule, but the top
                // 64pt of the card behaves like the handle (tap toggles, drag resizes), so
                // pulling the full view back down doesn't require landing on the thin handle.
                // In the expanded panel, leave the share button's trailing lane to the button.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(height: 64)
                        .contentShape(Rectangle())
                        .onTapGesture { snap(); withAnimation(spring) { expanded.toggle() } }
                        .gesture(resizeDrag(peekH: peekH, fullH: fullH))
                    if expanded {
                        Color.clear
                            .frame(width: 60, height: 64)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .sheet(isPresented: $model.showSearch) { SearchView().environmentObject(model) }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $model.showFunFacts) { FunFactsView().environmentObject(model) }
        .onChange(of: model.selection) {
            // Aggregate DMV navigation starts with no selected precinct. If the previous state
            // left this panel expanded, collapsing it here keeps the map and coverage selector
            // reachable instead of leaving a blank full-screen panel over them.
            if model.selection == nil {
                dragHeight = nil
                expanded = false
            }
        }
    }

    // Global coordinate space: the handle moves as the card resizes, so measuring the drag in its
    // own (moving) local space feeds back and makes it oscillate. Shared by the handle and the
    // peek-card catcher so both resize identically.
    private func resizeDrag(peekH: CGFloat, fullH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let base = expanded ? fullH : peekH
                dragHeight = min(fullH, max(peekH, base - value.translation.height))
            }
            .onEnded { value in
                if abs(value.translation.height) > 40 { snap() }
                // Decide the target, then clear the drag override and flip `expanded` in one
                // animated transaction so the height springs straight from where the finger
                // left it to the target — no intermediate snap.
                withAnimation(spring) {
                    if value.translation.height < -40 { expanded = true }
                    else if value.translation.height > 40 { expanded = false }
                    dragHeight = nil
                }
            }
    }

    // Tap toggles peek ↔ full; a drag on the handle tracks height live and snaps on release.
    private func handle(peekH: CGFloat, fullH: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { snap(); withAnimation(spring) { expanded.toggle() } }
            .gesture(resizeDrag(peekH: peekH, fullH: fullH))
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse panel" : "Expand panel")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(spring) { expanded.toggle() } }
    }
}

// The panel's scrollable contents. At peek only the lean headline shows (no scroll); expanding
// reveals the full profile.
private struct ProfileContent: View {
    @EnvironmentObject var model: LocationModel
    let showContent: Bool   // true once the card has grown past peek (drives the reveal)
    let scrolls: Bool       // only scroll when fully expanded
    private var baseline: Baseline? { model.stateBaseline }

    var body: some View {
        ScrollView {
            content
        }
        // At accessibility sizes the peek hero may still exceed even the taller peek,
        // so let it scroll instead of clipping the caveat lines.
        .scrollDisabled(!scrolls && !dts.isAccessibilitySize)
    }

    @Environment(\.dynamicTypeSize) private var dts

    @ViewBuilder
    private var content: some View {
            if let p = model.selection {
                VStack(spacing: 9) {
                    LeanHero(profile: p, showsShareButton: scrolls)
                    // Peek shows only the lean headline; the rest appears as the card grows so
                    // nothing bleeds in below the fold at rest.
                    if showContent {
                        if model.presidentTrend.count >= 2 {
                            TrajectoryBox(trend: model.presidentTrend)
                        }
                        WhoLivesHere(profile: p)
                        MoneyEducation(profile: p, baseline: baseline)
                        MoreStats(profile: p)
                        Text(p.leanYear.map { "\($0) presidential vote. Demographics use the 2020 Census and ACS." }
                             ?? "Election data is unavailable for this precinct. Demographics use the 2020 Census and ACS.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.horizontal).padding(.top, 4)
            } else if !PrecinctDB.shared.isAvailable {
                ContentUnavailableView("Data unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The precinct database couldn't be opened. Try reinstalling."))
                    .padding(.top, 40)
            } else {
                ContentUnavailableView("Tap the map", systemImage: "hand.tap",
                    description: Text("Tap anywhere in \(stateName(model.selectedState)) to see that precinct's profile."))
                    .padding(.top, 40)
            }
    }
}

// MARK: - Sheet section chrome
//
// The sheet used to stack four identical gray rounded cards, each with an SF Symbol glued to its
// header. Four containers of equal weight say "these are four boxes", not "this is a reading".
// A serif header over a ledger rule (the widget's and the share card's language) gives the same
// grouping with none of the boxes, and lets the numbers be the loudest thing on screen.
//
// This sheet was the last user of `Card` and `SmallStat`, so both were removed from
// BuildingBlocks rather than left behind as dead code. `BigStat` stays: By-the-Numbers still
// uses it, and that screen keeps its own (non-serif) treatment.

private struct SheetSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Side by side normally. At accessibility sizes a serif header and a "vs Queens"
            // menu cannot share one line without the header wrapping mid-phrase, so the
            // accessory drops to its own row instead.
            if dts.isAccessibilitySize {
                Text(title).font(.serifDisplay(17, .semibold))
                accessory
            } else {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.serifDisplay(17, .semibold))
                    Spacer(minLength: 4)
                    accessory
                }
            }
            Rectangle().fill(.secondary.opacity(0.28)).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

extension SheetSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, accessory: { EmptyView() })
    }
}

/// Picks what the "vs X" numbers compare against. Statewide tells you little about a
/// Brooklyn block when the state average is mostly New York City anyway.
private struct ComparisonMenu: View {
    @EnvironmentObject var model: LocationModel
    let current: Baseline

    var body: some View {
        Menu {
            ForEach(model.comparisonAreas, id: \.scope) { area in
                Button {
                    guard let p = model.selection,
                          let choice = ComparisonArea.allCases.first(where: { $0.scopeKey(for: p) == area.scope })
                    else { return }
                    model.comparisonPreference = choice
                } label: {
                    if area.scope == current.scope {
                        Label(area.displayName, systemImage: "checkmark")
                    } else {
                        Text(area.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("vs \(current.displayName)")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            // Same lesson as the By-the-Numbers chip: hold the width, let the neighbour give.
            // "vs San Bernardino" is a long label sitting next to a serif header.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .accessibilityLabel("Compare against, currently \(current.displayName)")
    }
}

/// Sheet-local stat views, serif-faced: the app's own convention is serif for display numbers,
/// and until now only the lean hero honoured it.
private struct SheetBigStat: View {
    let value: String
    let label: String
    let delta: (String, Bool)?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.serifDisplay(26, .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let delta {
                Text(delta.0).font(.caption2.bold())
                    .foregroundStyle(delta.1 ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SheetSmallStat: View {
    let title: String
    let value: String?
    init(_ title: String, _ value: String?) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.serifDisplay(19, .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1) Lean (the headline)

private struct LeanHero: View {
    @EnvironmentObject var model: LocationModel
    @Environment(\.dynamicTypeSize) private var dts
    let profile: PrecinctProfile
    let showsShareButton: Bool
    private var color: Color { Palette.lean(profile.leanDemShare) }
    private var labelText: String? { profile.leanLabel }
    private var localityText: String {
        "\(countyDisplay(profile.borough)), \(profile.state)"
            + (profile.precinctName.map { " (\(precinctDisplayName($0)))" } ?? "")
    }
    private var localityLineLimit: Int? {
        if !showsShareButton { return 1 }
        return dts.isAccessibilitySize ? nil : 2
    }
    private var leanAccessibilityText: String {
        var parts: [String] = []
        parts.append(profile.leanDemShare == nil ? "No election data" : "Political lean \(profile.leanShort)")
        if let labelText {
            parts.append(labelText + (profile.leanYear.map { " in \($0)" } ?? ""))
        }
        if let share = profile.leanDemShare {
            parts.append("\(Fmt.pct(share)) Democratic, \(Fmt.pct(1 - share)) Republican")
            if let votes = profile.leanVotes, votes < 100 {
                parts.append("Based on only \(votes) vote\(votes == 1 ? "" : "s") cast")
            }
            if let turnout = profile.turnoutEst, turnout <= 1.05 {
                parts.append("\(Fmt.pct(min(turnout, 1))) turnout"
                             + (profile.leanYear.map { " in \($0)" } ?? "")
                             + (profile.leanVotes.flatMap { $0 >= 100 ? " from \(Fmt.compact($0)) votes" : nil } ?? ""))
            }
        }
        return parts.joined(separator: ". ")
    }
    var body: some View {
        VStack(spacing: 5) {
            Text(localityText)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(localityLineLimit)
                .minimumScaleFactor(showsShareButton ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("Profile locality")
                // Reserve the button's width on both sides so the locality remains centered and
                // can never render underneath it. At peek there is no button and no reservation.
                .padding(.horizontal, showsShareButton ? 44 : 0)
                .overlay(alignment: .topTrailing) {
                    // This overlay belongs to the ScrollView, so it follows the hero instead of
                    // floating above it. It deliberately does not make the collapsed row taller.
                    if showsShareButton {
                        ShareCardButton(profile: profile, rings: model.selectedRings,
                                        trend: model.presidentTrend, baseline: model.stateBaseline)
                    }
                }

            VStack(spacing: 5) {
                Text(profile.leanShort)
                    .font(.serifDisplay(38, .heavy))
                    .foregroundStyle(color).contentTransition(.numericText())
                if let labelText {
                    Text(labelText + (profile.leanYear.map { " in \($0)" } ?? ""))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(color)
                }
                if let s = profile.leanDemShare {
                    TwoPartyBar(demShare: s).accessibilityHidden(true).padding(.top, 2)
                    HStack {
                        Text("\(Fmt.pct(s)) Dem").foregroundStyle(Palette.dem)
                        Spacer()
                        Text("\(Fmt.pct(1 - s)) Rep").foregroundStyle(Palette.rep)
                    }
                    .font(.caption)
                    // A precinct with a handful of ballots can read R+100; say so instead of
                    // letting the giant number stand alone. (100 matches By-the-Numbers' floor.)
                    if let v = profile.leanVotes, v < 100 {
                        Text("Based on only \(v) vote\(v == 1 ? "" : "s") cast")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let t = profile.turnoutEst, t <= 1.05 {
                        // "Votes cast" used to be an orphan tile down in the stat grid. Turnout is
                        // the number it qualifies, so they read as one line.
                        Text("\(Fmt.pct(min(t, 1))) turnout"
                             + (profile.leanYear.map { " in \($0)" } ?? "")
                             + (profile.leanVotes.flatMap { $0 >= 100 ? " from \(Fmt.compact($0)) votes" : nil } ?? ""))
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            // Now that this line carries the vote count too it can outrun one line at
                            // large text sizes; wrap rather than truncate the number away.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(leanAccessibilityText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - 1b) Presidential trajectory (replaces the terse "since '20" line)

private struct TrajectoryBox: View {
    let trend: [ElectionResult]   // president, sorted by year, demShare non-nil

    var body: some View {
        SheetSection(title: "Presidential trajectory") {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    // 30pt reserved under the bars: a deep-R bar bottoms out at `bottom`, its
                    // margin label sits fully below the bar, and the year row sits below that.
                    // (18pt used to force R+ labels onto the bar tip, where they vanished.)
                    let top: CGFloat = 16, bottom = h - 30
                    let n = max(1, trend.count)
                    // Column layout: even slots, bars centered with side padding so they fill the width.
                    let inset: CGFloat = 6
                    let slot = (w - inset * 2) / CGFloat(n)
                    let px: (Int) -> CGFloat = { i in inset + slot * (CGFloat(i) + 0.5) }
                    let barW = min(40, slot * 0.55)
                    // Scale to the actual data range so real swings fill the height, while keeping the
                    // "even" (50/50) baseline on-screen as a reference — clamped to an edge for precincts
                    // that never cross it, so the bars grow tall instead of clustering at mid-height.
                    let shares = trend.compactMap { $0.demShare }
                    let lo0 = shares.min() ?? 0.4, hi0 = shares.max() ?? 0.6
                    let pad = max(0.02, (hi0 - lo0) * 0.12)
                    let lo = min(0.5, lo0 - pad), hi = max(0.5, hi0 + pad)
                    let py: (Double) -> CGFloat = { s in bottom - CGFloat((s - lo) / (hi - lo)) * (bottom - top) }
                    ZStack {
                        ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                            let s = e.demShare ?? 0.5
                            let yEven = py(0.5), yVal = py(s), up = s >= 0.5
                            UnevenRoundedRectangle(topLeadingRadius: up ? 4 : 0, bottomLeadingRadius: up ? 0 : 4, bottomTrailingRadius: up ? 0 : 4, topTrailingRadius: up ? 4 : 0)
                                .fill(Palette.lean(s))
                                .frame(width: barW, height: max(2, abs(yVal - yEven)))
                                .position(x: px(i), y: (yEven + yVal) / 2)
                        }
                        // The 50/50 reference is drawn OVER the bars, not behind them. Behind, a
                        // year that only just crosses over (a 2pt bar hugging the line) read as a
                        // clipped or broken bar; an unbroken rule makes the crossing the point.
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: py(0.5)))
                            p.addLine(to: CGPoint(x: w, y: py(0.5)))
                        }
                        .stroke(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                            let s = e.demShare ?? 0.5
                            let yVal = py(s)
                            Text(margin(s)).font(.caption2.weight(.bold)).foregroundStyle(Palette.lean(s))
                                .position(x: px(i), y: s >= 0.5 ? max(8, yVal - 10) : min(yVal + 10, h - 22))
                            Text(String(e.year)).font(.caption2).foregroundStyle(.secondary)
                                .position(x: px(i), y: h - 6)
                        }
                    }
                }
                .frame(height: 100)
                // The chart is a fixed-height graphic with hand-positioned labels: let its
                // captions scale to accessibility sizes and the year row and margin labels
                // collide into each other. Clamped here only, and the chart already exposes the
                // whole series as one spoken accessibility label, which is the real reading path.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .accessibilityElement()
                .accessibilityLabel("Presidential margin over time: " + trend.map { "\($0.year) \(margin($0.demShare ?? 0.5))" }.joined(separator: ", "))
            }
        }
    }

    private func margin(_ s: Double) -> String {
        let m = Int((abs(s - 0.5) * 200).rounded())
        if m < 1 { return "Even" }
        return (s >= 0.5 ? "D+" : "R+") + "\(m)"
    }
}

// MARK: - 2) Who lives here

private struct WhoLivesHere: View {
    let profile: PrecinctProfile
    @State private var showInfo = false
    @Environment(\.dynamicTypeSize) private var dts
    private var rows: [(label: String, value: Double)] {
        profile.raceBreakdown.filter { $0.value >= 0.02 }
    }
    var body: some View {
        SheetSection(title: "Who lives here") {
            if rows.isEmpty {
                Text("No demographic data for this precinct.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let p = profile.pluralityGroup {
                    Text("Largest group: **\(p)**").font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.element.label) { idx, item in
                        HStack(spacing: 10) {
                            Text(item.label).font(.subheadline)
                                // The fixed column widths are what keep the bars aligned row to
                                // row. At accessibility sizes they clip names to "Hisp…", so the
                                // bar (decoration) gives way and the words get the whole row.
                                .frame(width: dts.isAccessibilitySize ? nil : 86, alignment: .leading)
                                .lineLimit(dts.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                            // Flat bars on bare paper, not capsules in a trough: a rounded pill on
                            // a grey track is the shape of a download progress bar, and these are
                            // measurements. The rows share a left edge, so the track was only ever
                            // drawing a 100% reference nobody reads, louder than the small bars.
                            if !dts.isAccessibilitySize {
                                GeometryReader { geo in
                                    Rectangle().fill(Palette.rankTint(idx))
                                        .frame(width: max(3, geo.size.width * min(1, item.value)))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 7)
                                .accessibilityHidden(true)
                            } else {
                                Spacer(minLength: 4)
                            }
                            Text(Fmt.pct(item.value)).font(.subheadline.weight(.semibold).monospacedDigit())
                                .frame(width: dts.isAccessibilitySize ? nil : 46, alignment: .trailing)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.label), \(Fmt.pct(item.value))")
                    }
                }
                if rows.reduce(0.0, { $0 + $1.value }) > 1.001 {
                Button { showInfo = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        Text("Why can shares total over 100%?")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .alert("Race & ethnicity", isPresented: $showInfo) {
                    Button("Got It", role: .cancel) {}
                } message: {
                    Text("The U.S. Census asks about race and Hispanic/Latino ethnicity as two separate questions, so a person is often counted in both. Shares overlap and can exceed 100%. \"Other race\" is the Census \"Some Other Race\" category, which many Hispanic residents select.")
                }
                }
            }
        }
    }
}

// MARK: - 3) Money & education

private struct MoneyEducation: View {
    @EnvironmentObject var model: LocationModel
    let profile: PrecinctProfile
    let baseline: Baseline?
    var body: some View {
        // Every label comes from the RESOLVED baseline, never from the preference, so a reader
        // who picked "county" and landed in a 4-precinct Texas county sees "vs TX" and the
        // number describes itself correctly instead of lying about what it measured.
        SheetSection(title: "Money and education") {
            HStack(alignment: .top, spacing: 12) {
                // ACS income is top-coded at the 250001 sentinel. By-the-Numbers and the share
                // card already showed that honestly as "$250k+"; this screen was still printing
                // the raw sentinel as "$250,001".
                SheetBigStat(value: profile.incomeMedian.map { Fmt.incomeTopCoded($0) } ?? "—",
                             label: "Median income",
                             delta: Delta.money(profile.incomeMedian, baseline?.incomeMedian, baseline?.displayName ?? profile.state))
                SheetBigStat(value: profile.pctBachelorsOrHigher.map { Fmt.pct($0) } ?? "—",
                             label: "College degree",
                             delta: Delta.points(profile.pctBachelorsOrHigher, baseline?.pctBachelorsOrHigher, baseline?.displayName ?? profile.state))
            }
        } accessory: {
            if let baseline, model.comparisonAreas.count > 1 {
                ComparisonMenu(current: baseline)
            }
        }
    }
}

// MARK: - 4) People and housing
//
// Was "Everything else", which is a section admitting it never decided what it holds. Every
// reading here is about who lives in the precinct and how they're housed; "Votes cast" was the
// one that didn't fit, and it now sits with turnout up in the hero where it belongs.

private struct MoreStats: View {
    let profile: PrecinctProfile
    var body: some View {
        SheetSection(title: "People and housing") {
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 16) {
                SheetSmallStat("Population", profile.popTotal.map { Fmt.compact($0) })
                SheetSmallStat("Median age", profile.avgAge.map { String(Int($0.rounded())) })
                SheetSmallStat("Density", profile.popDensity.map { "\(Fmt.compact(Int($0)))/mi²" })
                SheetSmallStat("Renters", profile.pctRenter.map { Fmt.pct($0) })
                SheetSmallStat("Owners", profile.pctOwner.map { Fmt.pct($0) })
            }
        }
    }
}
