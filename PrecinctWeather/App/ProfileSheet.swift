import SwiftUI
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
    // Single source of truth for the live drag height; nil at rest (height follows `expanded`).
    // Using @State (not @GestureState) so the release can clear it together with `expanded` in one
    // animated transaction — otherwise @GestureState's auto-reset fires in a separate frame and the
    // card jumps to its old size before springing to the new one.
    @State private var dragHeight: CGFloat? = nil
    private var spring: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { geo in
            let fullH = max(Self.peekHeight, geo.size.height)
            let restH = expanded ? fullH : Self.peekHeight
            let height = dragHeight ?? restH
            VStack(spacing: 0) {
                handle(fullH: fullH)
                // Reveal the full profile as soon as the card grows past peek (not only at the end
                // of the drag), so expanding fills in continuously instead of staying blank then
                // popping everything in at once.
                ProfileContent(showContent: height > Self.peekHeight + 2, scrolls: expanded)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .background {
                // Material extended down through the home-indicator strip via negative padding
                // (NOT ignoresSafeArea, which makes the greedy shape fill the whole screen) so the
                // card sits flush to the bottom edge — no map showing underneath.
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
                    .padding(.bottom, -geo.safeAreaInsets.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .sheet(isPresented: $model.showSearch) { SearchView().environmentObject(model) }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $model.showFunFacts) { FunFactsView().environmentObject(model) }
    }

    // Tap toggles peek ↔ full; a drag on the handle tracks height live and snaps on release.
    private func handle(fullH: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(spring) { expanded.toggle() } }
            .gesture(
                // Global coordinate space: the handle moves as the card resizes, so measuring the
                // drag in its own (moving) local space feeds back and makes it oscillate.
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        let base = expanded ? fullH : Self.peekHeight
                        dragHeight = min(fullH, max(Self.peekHeight, base - value.translation.height))
                    }
                    .onEnded { value in
                        // Decide the target, then clear the drag override and flip `expanded` in one
                        // animated transaction so the height springs straight from where the finger
                        // left it to the target — no intermediate snap.
                        withAnimation(spring) {
                            if value.translation.height < -40 { expanded = true }
                            else if value.translation.height > 40 { expanded = false }
                            dragHeight = nil
                        }
                    }
            )
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
            if let p = model.selection {
                VStack(spacing: 9) {
                    LeanHero(profile: p)
                    // Peek shows only the lean headline; the rest appears as the card grows so
                    // nothing bleeds in below the fold at rest.
                    if showContent {
                        if model.presidentTrend.count >= 2 {
                            TrajectoryBox(trend: model.presidentTrend)
                        }
                        WhoLivesHere(profile: p)
                        MoneyEducation(profile: p, baseline: baseline)
                        MoreStats(profile: p)
                        Text("\(p.leanYear.map(String.init) ?? "Latest") presidential vote. 2020 Census and ACS.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                        Color.clear.frame(height: 12)
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
        .scrollDisabled(!scrolls)
    }
}

// MARK: - 1) Lean (the headline)

private struct LeanHero: View {
    let profile: PrecinctProfile
    private var color: Color { Palette.lean(profile.leanDemShare) }
    private var labelText: String? {
        profile.leanLabel ?? (profile.leanDemShare == nil ? "No election data" : nil)
    }
    var body: some View {
        VStack(spacing: 5) {
            Text("\(countyDisplay(profile.borough)), \(profile.state)" + (profile.precinctName.map { " · \($0)" } ?? ""))
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(profile.leanShort)
                .font(.system(size: 38, weight: .heavy, design: .serif))
                .foregroundStyle(color).contentTransition(.numericText())
            if let labelText {
                Text(labelText + (profile.leanYear.map { " in \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(color)
            }
            if let s = profile.leanDemShare {
                TwoPartyBar(demShare: s).accessibilityHidden(true).padding(.top, 2)
                HStack {
                    Text("\(Fmt.pct(s)) Dem").foregroundStyle(.blue)
                    Spacer()
                    Text("\(Fmt.pct(1 - s)) Rep").foregroundStyle(.red)
                }
                .font(.caption)
                if let t = profile.turnoutEst, t <= 1.05 {
                    Text("\(Fmt.pct(min(t, 1))) turnout" + (profile.leanYear.map { " in \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.borough). Political lean \(profile.leanShort), \(profile.leanLabel ?? "no election data")")
    }
}

// MARK: - 1b) Presidential trajectory (replaces the terse "since '20" line)

private struct TrajectoryBox: View {
    let trend: [ElectionResult]   // president, sorted by year, demShare non-nil

    var body: some View {
        Card(title: "Presidential trajectory", systemImage: "chart.line.uptrend.xyaxis") {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let top: CGFloat = 16, bottom = h - 18
                    let n = max(1, trend.count)
                    let px: (Int) -> CGFloat = { i in n == 1 ? w / 2 : 12 + (w - 24) * CGFloat(i) / CGFloat(n - 1) }
                    // Zoom the vertical axis to the data (symmetric around even) so real swings read
                    // clearly instead of nearly flat on a full 0...1 scale. The floor keeps tiny changes
                    // from looking dramatic; the 1.2x padding keeps points off the top and bottom edges.
                    let dev = trend.compactMap { $0.demShare }.map { abs($0 - 0.5) }.max() ?? 0.1
                    let span = max(0.07, dev * 1.2)
                    let py: (Double) -> CGFloat = { s in (top + bottom) / 2 - CGFloat((s - 0.5) / span) * (bottom - top) / 2 }
                    ZStack {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: py(0.5)))
                            p.addLine(to: CGPoint(x: w, y: py(0.5)))
                        }
                        .stroke(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        Path { p in
                            for (i, e) in trend.enumerated() {
                                let pt = CGPoint(x: px(i), y: py(e.demShare ?? 0.5))
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                        }
                        .stroke(.primary.opacity(0.45), lineWidth: 2)
                        ForEach(Array(trend.enumerated()), id: \.offset) { i, e in
                            let s = e.demShare ?? 0.5
                            Circle().fill(Palette.lean(s)).frame(width: 11, height: 11)
                                .position(x: px(i), y: py(s))
                            Text(margin(s)).font(.caption2.weight(.bold)).foregroundStyle(Palette.lean(s))
                                .position(x: px(i), y: max(8, py(s) - 14))
                            Text(String(e.year)).font(.caption2).foregroundStyle(.secondary)
                                .position(x: px(i), y: h - 6)
                        }
                    }
                }
                .frame(height: 54)
                .accessibilityElement()
                .accessibilityLabel("Presidential margin over time: " + trend.map { "\($0.year) \(margin($0.demShare ?? 0.5))" }.joined(separator: ", "))
                Text("Two-party presidential margin. Dashed line is even.")
                    .font(.caption2).foregroundStyle(.tertiary)
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
    private var rows: [(label: String, value: Double)] {
        profile.raceBreakdown.filter { $0.value >= 0.02 }
    }
    var body: some View {
        Card(title: "Who lives here", systemImage: "person.3.fill") {
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
                                .frame(width: 86, alignment: .leading)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(.tertiarySystemFill))
                                    Capsule().fill(Palette.rankTint(idx))
                                        .frame(width: max(6, geo.size.width * min(1, item.value)))
                                }
                            }
                            .frame(height: 14)
                            .accessibilityHidden(true)
                            Text(Fmt.pct(item.value)).font(.subheadline.weight(.semibold).monospacedDigit())
                                .frame(width: 46, alignment: .trailing)
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
                        Text("Shares can total over 100% — why?")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .alert("Race & ethnicity", isPresented: $showInfo) {
                    Button("Got it", role: .cancel) {}
                } message: {
                    Text("The U.S. Census asks about race and Hispanic/Latino ethnicity as two separate questions, so a person is often counted in both — shares overlap and can exceed 100%. \"Other race\" is the Census \"Some Other Race\" category, which many Hispanic residents select.")
                }
                }
            }
        }
    }
}

// MARK: - 3) Money & education

private struct MoneyEducation: View {
    let profile: PrecinctProfile
    let baseline: Baseline?
    var body: some View {
        Card(title: "Money & education", systemImage: "dollarsign.circle.fill") {
            HStack(alignment: .top, spacing: 12) {
                BigStat(value: profile.incomeMedian.map { Fmt.money($0) } ?? "—",
                        label: "Median income",
                        delta: Delta.money(profile.incomeMedian, baseline?.incomeMedian, profile.state))
                BigStat(value: profile.pctBachelorsOrHigher.map { Fmt.pct($0) } ?? "—",
                        label: "Bachelor's+",
                        delta: Delta.points(profile.pctBachelorsOrHigher, baseline?.pctBachelorsOrHigher, profile.state))
            }
        }
    }
}

// MARK: - 4) Everything else

private struct MoreStats: View {
    let profile: PrecinctProfile
    var body: some View {
        Card(title: "More", systemImage: "chart.bar.fill") {
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 16) {
                SmallStat("Median age", profile.avgAge.map { String(Int($0.rounded())) })
                SmallStat("Renters", profile.pctRenter.map { Fmt.pct($0) })
                SmallStat("Population", profile.popTotal.map { Fmt.compact($0) })
                SmallStat("Density", profile.popDensity.map { "\(Fmt.compact(Int($0)))/mi²" })
                SmallStat("Owners", profile.pctOwner.map { Fmt.pct($0) })
                SmallStat("Votes cast", profile.leanVotes.map { Fmt.compact($0) })
            }
        }
    }
}
