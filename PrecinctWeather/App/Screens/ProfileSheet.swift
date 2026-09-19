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
    @State private var unitWhenNumbersOpened: String?
    @Binding var expanded: Bool

    static var peekHeight: CGFloat { 212}
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86) }
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
                    .zIndex(1)
                // Reveal the full profile as soon as the card grows past peek (not only at the end
                // of the drag), so expanding fills in continuously instead of staying blank then
                // popping everything in at once.
                ProfileContent(showContent: height > peekH + 2, scrolls: expanded)
                    // The scroll view starts at the card's top edge and keeps the handle's height
                    // as a margin, so text slides under the handle and the rounded edge.
                    .modifier(UnderHandle(inset: 20, radius: Brand.sheetCorner, bottom: geo.safeAreaInsets.bottom))
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
            .tourTarget(.card)
            .background {
                // Extended down through the home-indicator strip via negative padding (NOT
                // ignoresSafeArea, which makes the greedy shape fill the whole screen) so the card
                // sits flush to the bottom edge with no map showing underneath.
                // Opaque, not material: the frosted panel live-blurred the map (tint polygons
                // included) on every frame of a drag, which is what made resizing feel heavy
                // in polygon-dense counties. A solid card costs nothing to move.
                UnevenRoundedRectangle(topLeadingRadius: Brand.sheetCorner, topTrailingRadius: Brand.sheetCorner)
                    .fill(Brand.surface)
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
        .onChange(of: model.showFunFacts) {
            // Picking a precinct inside By the Numbers lands in the small card, so the map shows
            // where it is before the details.
            if model.showFunFacts {
                unitWhenNumbersOpened = model.selection?.unitID
            } else if model.selection?.unitID != unitWhenNumbersOpened, model.selection != nil {
                withAnimation(spring) { dragHeight = nil; expanded = false }
            }
        }
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
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture { snap(); withAnimation(spring) { expanded.toggle() } }
            .gesture(resizeDrag(peekH: peekH, fullH: fullH))
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse panel" : "Expand panel")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(spring) { expanded.toggle() } }
    }
}

private struct UnderHandle: ViewModifier {
    let inset: CGFloat
    let radius: CGFloat
    var bottom: CGFloat = 0
    func body(content: Content) -> some View {
        // Text slides under the handle and the rounded edge at the top, and under the home
        // indicator at the bottom, instead of stopping at a hard edge.
        content
            .contentMargins(.top, inset, for: .scrollContent)
            .contentMargins(.bottom, bottom + 12, for: .scrollContent)
            .padding(.top, -inset)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
            .ignoresSafeArea(.container, edges: .bottom)
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
        ScrollViewReader { proxy in
            ScrollView {
                content.id("profileTop")
                Color.clear.frame(height: 1).id("profileEnd")
                #if DEBUG
                // Screenshot capture only: SwiftUI's bottom anchor stops short by the top safe-area
                // inset here, so pad by that much to land on the real end of the card.
                if ProcessInfo.processInfo.arguments.contains("-scrollProfileEnd") { Color.clear.frame(height: 82) }
                #endif
            }
            // At accessibility sizes the peek hero may still exceed even the taller peek,
            // so let it scroll instead of clipping the caveat lines.
            .scrollDisabled(!scrolls && !dts.isAccessibilitySize)
            // Collapsing, or picking another precinct at peek, returns to the top. Otherwise the
            // peek keeps the old offset and cuts the place name off.
            .onChange(of: scrolls) { if !scrolls { proxy.scrollTo("profileTop", anchor: .top) } }
            .onChange(of: model.selection?.unitID) { if !scrolls { proxy.scrollTo("profileTop", anchor: .top) } }
            #if DEBUG
            // Screenshot capture: the card opened at its end.
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-scrollProfileEnd") ? .bottom : nil)
            #endif
        }
    }

    /// Which election the card uses. A precinct that missed the latest one names the result
    /// its chart does show.
    private func footnote(_ p: PrecinctProfile) -> String {
        let demographics = "Demographics use the 2020 Census and the American Community Survey."
        if let y = p.leanYear { return "\(String(y)) presidential vote. " + demographics }
        if let latest = model.presidentTrend.last(where: { $0.demShare != nil }) {
            return "\(String(latest.year)) presidential vote, the latest available. " + demographics
        }
        return "Election data is unavailable for this precinct. " + demographics
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
                        Text(footnote(p))
                            .brandNoteStyle()
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
                // Left aligned like the hero it will become, and short enough for the peek.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tap a precinct").brandScaledDisplay(26, .bold)
                    Text("Anywhere on the map in \(stateName(model.selectedState)).")
                        .font(.bt(.subheadline)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 22)
            
            }
    }
}

// MARK: - Sheet section chrome

/// One card section: a `BrandSectionHeader` (a title with one rule under it) over its content.
private struct SheetSection<Content: View, Accessory: View>: View {
    let title: String
    var link: Metric? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    @EnvironmentObject var model: LocationModel
    @Environment(\.dynamicTypeSize) private var dts
    var body: some View {
        // Only the header links to By the Numbers. Wrapping the whole section in a button would
        // merge the comparison menu and the info button into it for VoiceOver.
        VStack(alignment: .leading, spacing: 9) {
            BrandSectionHeader(title: title, stacked: dts.isAccessibilitySize,
                               onTap: link.map { metric in { model.numbersFocus = metric; model.showFunFacts = true } }) { accessory }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

extension SheetSection where Accessory == EmptyView {
    init(title: String, link: Metric? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, link: link, content: content, accessory: { EmptyView() })
    }
}

/// Picks what the "vs X" numbers compare against. Statewide tells you little about a
/// Brooklyn block when the state average is mostly New York City anyway.
private struct ComparisonMenu: View {
    @EnvironmentObject var model: LocationModel
    let current: Baseline

    static func menuLabel(_ scope: String) -> (String, String) {
        let parts = scope.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "county" where parts.count == 3:
            let boroughs: Set<String> = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"]
            let kind = boroughs.contains(parts[2]) ? "Borough"
                : parts[2] == "District of Columbia" ? "District"
                : parts[2].hasSuffix(" City") ? "City" : "County"
            return (countyDisplay(parts[2]), kind)
        case "metro" where parts.count == 3: return (parts[2], "City")
        case "region": return ("DMV (DC, MD, VA)", "Region")
        default: return (stateName(scope), "State")
        }
    }

    var body: some View {
        Menu {
            ForEach(model.comparisonAreas, id: \.scope) { area in
                Button {
                    guard let p = model.selection,
                          let choice = ComparisonArea.allCases.first(where: { $0.scopeKey(for: p) == area.scope })
                    else { return }
                    model.comparisonPreference = choice
                } label: {
                    // Full name with its kind under it, always ordered county, city or region,
                    // then state, so "Manhattan / NYC / NY" reads as one clear ladder.
                    let (name, kind) = Self.menuLabel(area.scope)
                    if area.scope == current.scope {
                        Label { Text(name); Text(kind) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(name); Text(kind)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("vs \(current.readerName)")
                Image(systemName: "chevron.down").font(.bt(.caption2))
            }
            .font(.bt(.caption, .semibold))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            // An explicit color: .secondary inside a Menu label is dimmed a second time and read
            // as disabled in dark mode.
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            // Hold the width and let the header give way. "vs San Bernardino" is a long label.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Brand.chipShape)
        }
        .accessibilityLabel("Compare against, currently \(current.readerName)")
    }
}

/// Makes a stat open By the Numbers on the same measure, with this precinct marked. The chevron
/// beside the label says it can be tapped.
private struct NumbersLink<Content: View>: View {
    @EnvironmentObject var model: LocationModel
    let metric: Metric?
    @ViewBuilder var content: Content
    var body: some View {
        if let metric {
            Button {
                model.numbersFocus = metric
                model.showFunFacts = true
            } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityHint("Opens By the Numbers")
        } else {
            content
        }
    }
}

/// A stat's label. No chevron: the whole stat is the link, and the section header's chevron is
/// the one cue that the numbers open By the Numbers.
private func statLabel(_ text: String, linked: Bool) -> Text {
    Text(text)
}

private struct SheetBigStat: View {
    let value: String
    let label: String
    /// Lets the figure run into an empty neighboring grid column instead of shrinking.
    var overflow = false
    let delta: (String, Bool)?
    var metric: Metric? = nil
    var body: some View {
        NumbersLink(metric: metric) { inner }
    }
    private var inner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .brandScaledFigure(26, .semibold).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(overflow ? 1 : 0.7)
                .fixedSize(horizontal: overflow, vertical: false)
            // Labels and deltas stop growing before the figure does, so the number stays loudest.
            Group {
                statLabel(label, linked: metric != nil).font(.bt(.caption)).foregroundStyle(.secondary)
                if let delta {
                    Text(delta.0).font(.bt(.caption2, .bold))
                        .foregroundStyle(delta.1 ? Brand.deltaUp : Brand.deltaDown)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element per stat, like the race rows and the hero. VoiceOver reads it in one pass.
        .accessibilityElement(children: .combine)
    }
}

private struct SheetSmallStat: View {
    let title: String
    let value: String?
    let metric: Metric?
    init(_ title: String, _ value: String?, metric: Metric? = nil) { self.title = title; self.value = value; self.metric = metric }
    var body: some View {
        NumbersLink(metric: metric) { inner }
    }
    private var inner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .brandScaledFigure(19, .semibold).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            statLabel(title, linked: metric != nil).font(.bt(.caption2)).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        // "Precinct 1322, Queens, NY", the same name the share card and widget use.
        "\(precinctHeadline(profile)), \(precinctArea(profile))"
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
            if let line = votesLine(profile, compact: Fmt.compact, showVotes: (profile.leanVotes ?? 0) >= 100) {
                parts.append(line)
            }
        }
        return parts.joined(separator: ". ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(localityText)
                .font(.bt(.subheadline)).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .multilineTextAlignment(.leading)
                .lineLimit(localityLineLimit)
                .minimumScaleFactor(showsShareButton ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("Profile locality")
                // Reserve the share button's width so the locality can never render underneath
                // it. At peek there is no button and no reservation.
                .padding(.trailing, showsShareButton ? 44 : 0)
                .overlay(alignment: .topTrailing) {
                    // This overlay belongs to the ScrollView, so it follows the hero instead of
                    // floating above it. It deliberately does not make the collapsed row taller.
                    if showsShareButton {
                        ShareCardButton(profile: profile, polygons: model.selectedPolygons,
                                        trend: model.presidentTrend, baseline: model.stateBaseline)
                    }
                }

            // Open card: the whole lean block opens the lean chart, the same way every number on
            // the card opens its chart. At peek a tap expands the card instead.
            NumbersLink(metric: showsShareButton && profile.leanDemShare != nil ? .lean : nil) {
            VStack(alignment: .leading, spacing: 5) {
                if profile.leanDemShare == nil {
                    // A precinct can miss the latest election but still have earlier results.
                    // Saying "No election data" above a chart of results contradicted itself.
                    let latest = model.presidentTrend.last(where: { $0.demShare != nil })
                    Text(latest.map { $0.year < 2024 ? "No 2024 result" : "No election data" } ?? "No election data")
                        .brandScaledDisplay(30, .heavy).foregroundStyle(.secondary)
                    if let e = latest, let s = e.demShare {
                        Text("Latest result \(Metric.lean.format(s)) in \(String(e.year))")
                            .font(.bt(.subheadline, .semibold)).foregroundStyle(Palette.lean(s))
                    }
                } else {
                Text(profile.leanShort)
                    .brandScaledDisplay(Brand.heroSize, .heavy)
                    .foregroundStyle(color).contentTransition(.numericText())
                }
                if let labelText {
                    Text(labelText + (profile.leanYear.map { " in \($0)" } ?? ""))
                        .font(.bt(.subheadline, .semibold)).foregroundStyle(Palette.lean(profile.leanDemShare))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = profile.leanDemShare {
                    TwoPartyBar(demShare: s).accessibilityHidden(true).padding(.top, 2)
                    HStack {
                        Text("\(Fmt.pct(s)) Dem").foregroundStyle(Palette.dem)
                        Spacer()
                        Text("\(Fmt.pct(1 - s)) Rep").foregroundStyle(Palette.rep)
                    }
                    .font(.bt(.caption))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    // A precinct with a handful of ballots can read R+100; say so instead of
                    // letting the giant number stand alone. (100 matches By-the-Numbers' floor.)
                    if let v = profile.leanVotes, v < 100 {
                        Text("Based on only \(v) vote\(v == 1 ? "" : "s") cast")
                            .font(.bt(.caption2, .semibold)).foregroundStyle(.secondary)
                    }
                    // The vote count and the share of eligible adults, as one line. California has no
                    // turnout, so it shows the vote count alone.
                    if let line = votesLine(profile, compact: Fmt.compact, showVotes: (profile.leanVotes ?? 0) >= 100) {
                        Text(line)
                            .font(.bt(.caption2)).foregroundStyle(.secondary)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(leanAccessibilityText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - 1b) Presidential trajectory

private struct TrajectoryBox: View {
    let trend: [ElectionResult]   // president, sorted by year, demShare non-nil

    var body: some View {
        SheetSection(title: "Politics", link: .shift) {
            VStack(spacing: 4) {
                Text("Presidential margin by year").font(.bt(.headline, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, alignment: .leading)
            
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
                    let barW = min(Brand.chartWidth, slot * 0.6)
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
                            let yEven = py(0.5), yVal = py(s)
                            Rectangle()
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
                            Text(margin(s)).font(.bt(.caption2, .bold)).foregroundStyle(Palette.lean(s))
                                .position(x: px(i), y: s >= 0.5 ? max(8, yVal - 10) : min(yVal + 10, h - 22))
                            Text(String(e.year)).font(.bt(.caption2)).foregroundStyle(.secondary)
                                .position(x: px(i), y: h - 6)
                        }
                    }
                }
                .frame(height: 100)
                .padding(.bottom, 3)
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
        SheetSection(title: "Who lives here", link: .largestGroup) {
            if rows.isEmpty {
                Text("No demographic data for this precinct.")
                    .font(.bt(.subheadline)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.element.label) { idx, item in
                        HStack(spacing: 10) {
                            Text(item.label).font(.bt(.subheadline, .medium))
                                // The fixed column widths are what keep the bars aligned row to
                                // row. At accessibility sizes they clip names to "Hisp…", so the
                                // bar (decoration) gives way and the words get the whole row.
                                // No per-row shrinking: every name renders at one size.
                                .frame(width: dts.isAccessibilitySize ? nil : (104), alignment: .leading)
                                .lineLimit(dts.isAccessibilitySize ? 2 : 1).minimumScaleFactor(1)
                            // Flat bars with no track: a rounded pill on a gray track reads as a
                            // progress bar, and these are measurements.
                            if !dts.isAccessibilitySize {
                                GeometryReader { geo in
                                    Rectangle().fill(Palette.rankTint(idx))
                                        .frame(width: max(3, geo.size.width * min(1, item.value)))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 10)
                                .accessibilityHidden(true)
                            } else {
                                Spacer(minLength: 4)
                            }
                            Text(Fmt.pct(item.value)).font(.bt(.subheadline, .semibold).monospacedDigit())
                                .frame(width: dts.isAccessibilitySize ? nil : 46, alignment: .trailing)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        // Rows stop growing where the section header does, so a header is never
                        // smaller than the rows under it.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
                    .font(.bt(.caption2)).foregroundStyle(.secondary)
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
    @Environment(\.dynamicTypeSize) private var dts
    let profile: PrecinctProfile
    let baseline: Baseline?
    var body: some View {
        // Every label comes from the RESOLVED baseline, never from the preference, so a reader
        // who picked "county" and landed in a 4-precinct Texas county sees "vs TX" and the
        // number describes itself correctly instead of lying about what it measured.
        SheetSection(title: "Money and education", link: .income) {
            // ACS income is top-coded at the 250001 sentinel. By-the-Numbers and the share
            // card already showed that honestly as "$250k+"; this screen was still printing
            // the raw sentinel as "$250,001".
            let stats = Group {
                SheetBigStat(value: profile.incomeMedian.map { Fmt.incomeTopCoded($0) } ?? "—",
                             label: "Median income", overflow: true,
                             delta: Delta.money(profile.incomeMedian, baseline?.incomeMedian, ""),
                             metric: .income)
                // Column two stays empty so a six-digit income has room and College lines up
                // with the third column (Density) below.
                if !dts.isAccessibilitySize { Color.clear.frame(height: 0) }
                SheetBigStat(value: profile.pctBachelorsOrHigher.map { Fmt.pct($0) } ?? "—",
                             label: "College degree",
                             delta: Delta.points(profile.pctBachelorsOrHigher, baseline?.pctBachelorsOrHigher, ""),
                             metric: .college)
            }
            // The same three columns as People and housing, so column two lines up down the card.
            // One column at accessibility sizes, laid out eagerly (see StatColumn).
            if dts.isAccessibilitySize {
                StatColumn { stats }
            } else {
                let cols = Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3)
                LazyVGrid(columns: cols, alignment: .leading, spacing: 16) { stats }
            }
        } accessory: {
            if let baseline, model.comparisonAreas.count > 1 {
                ComparisonMenu(current: baseline)
            }
        }
    }
}

// MARK: - 4) People and housing

private struct MoreStats: View {
    @Environment(\.dynamicTypeSize) private var dts
    let profile: PrecinctProfile
    var body: some View {
        SheetSection(title: "People and housing", link: .age) {
            let stats = Group {
                SheetSmallStat("Population", profile.popTotal.map { Fmt.compact($0) })
                SheetSmallStat("Median age", profile.avgAge.map { String(Int($0.rounded())) }, metric: .age)
                SheetSmallStat("Density", profile.popDensity.map { "\(Metric.density.format($0))/mi²" }, metric: .density)
                SheetSmallStat("Renters", profile.pctRenter.map { Fmt.pct($0) }, metric: .renters)
                SheetSmallStat("Owners", profile.pctOwner.map { Fmt.pct($0) }, metric: .renters)
            }
            if dts.isAccessibilitySize {
                StatColumn { stats }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 16) { stats }
            }
        }
    }
}

/// The card's stats as one column at accessibility sizes. A plain stack, not a one-column lazy
/// grid: with the lazy grid, the text clipping audit flagged the stat labels after a fast scroll,
/// though the text was drawn in full. With this stack it did not.
private struct StatColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

