import SwiftUI
import CoreLocation

// MARK: - First-run tour
//
// A short guided pass over the real app. Each step dims the screen, leaves the real control lit,
// and moves on when the reader uses that control. Nothing here draws a fake map or a fake card.
// ContentView owns the side effects (camera, panel, location) and reports the reader's actions.

@MainActor
final class OnboardingTour: ObservableObject {
    static let shared = OnboardingTour()

    enum Step: Int, CaseIterable {
        // The area comes first, so a new reader starts on a state they care about.
        case welcome, coverage, tap, card, numbers, search, location
    }

    enum Outcome { case finished, skippedAll }

    @Published private(set) var step: Step?
    /// Second half of the card step: the panel is up and the reader should pull it back down.
    @Published var cardOpened = false
    private(set) var isReplay = false
    private(set) var outcome: Outcome = .finished
    /// The reader chose "Not now" on the location step.
    private(set) var declinedLocation = false
    private(set) var steps: [Step] = []

    /// Search step bookkeeping: the selection revision when the search sheet opened.
    var searchOpenedAt: Int?
    var numbersOpened = false

    var isActive: Bool { step != nil }

    func start(replay: Bool) {
        isReplay = replay
        outcome = .finished
        declinedLocation = false
        cardOpened = false
        searchOpenedAt = nil
        numbersOpened = false
        // Denied or restricted location turns the Locate button into a Settings alert, so the
        // step would only raise that alert. Skip it then.
        let status = CLLocationManager().authorizationStatus
        let locationUsable = status != .denied && status != .restricted
        steps = Step.allCases.filter { $0 != .welcome && ($0 != .location || locationUsable) }
        step = .welcome
    }

    func begin() { step = steps.first }

    /// Moves to the next step, or ends the tour after the last one.
    func next() {
        cardOpened = false
        searchOpenedAt = nil
        numbersOpened = false
        guard let step, let i = steps.firstIndex(of: step), i + 1 < steps.count else {
            outcome = .finished
            self.step = nil
            return
        }
        self.step = steps[i + 1]
    }

    func declineLocation() {
        declinedLocation = true
        next()
    }

    func skipAll() {
        outcome = .skippedAll
        cardOpened = false
        step = nil
    }

    /// "2 of 6" style position, counted over the steps this run will show.
    var position: (index: Int, count: Int)? {
        guard let step, let i = steps.firstIndex(of: step) else { return nil }
        return (i + 1, steps.count)
    }
}

// MARK: - Anchors on the real controls

enum TourTarget: Hashable {
    case topBar, search, area, numbers, locate, card
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks a real control so the tour can light it up.
    func tourTarget(_ target: TourTarget) -> some View {
        // Transform, not set: a plain anchorPreference on the top bar would replace the anchors
        // its own buttons report.
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[target] = $1 }
    }
}

// MARK: - Overlay

/// Everything the tour draws over the app: the welcome screen, then a dim with one lit control
/// and a short caption beside it.
struct TourLayer: View {
    @ObservedObject var tour: OnboardingTour
    let anchors: [TourTarget: Anchor<CGRect>]
    let locationAuthorized: Bool
    /// The area the map shows now, for the coverage step's "Keep New York" choice.
    let areaName: String
    /// VoiceOver fallbacks. Each performs the same model action as the real control.
    let perform: (OnboardingTour.Step) -> Void
    let onBegin: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// UI tests turn on the VoiceOver-only buttons with this flag to drive that path.
    private var voiceOver: Bool {
        #if DEBUG
        voiceOverEnabled || ProcessInfo.processInfo.arguments.contains("-tourVoiceOverActions")
        #else
        voiceOverEnabled
        #endif
    }
    @AccessibilityFocusState private var captionFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            if let step = tour.step {
                if step == .welcome {
                    TourWelcome(onStart: onBegin, onSkip: { tour.skipAll() })
                        .transition(.opacity)
                } else {
                    stepLayer(step, proxy: proxy)
                }
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: tour.step)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: tour.cardOpened)
    }

    private var insets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
    }

    /// The lit rectangle for a step, in this layer's full-screen space.
    private func hole(_ step: OnboardingTour.Step, proxy: GeometryProxy) -> CGRect? {
        func rect(_ t: TourTarget) -> CGRect? { anchors[t].map { proxy[$0] } }
        let size = proxy.size
        switch step {
        case .welcome: return nil
        case .tap:
            // The open map between the top controls and the peek card.
            guard let bar = rect(.topBar), let card = rect(.card) else { return nil }
            // Stop above the Locate button so it stays dimmed until its own step.
            let top = bar.maxY + 14, bottom = min(card.minY, rect(.locate)?.minY ?? card.minY) - 14
            guard bottom - top > 80 else { return nil }
            return CGRect(x: 12, y: top, width: size.width - 24, height: bottom - top)
        case .card:
            guard let card = rect(.card) else { return nil }
            return CGRect(x: 0, y: card.minY, width: size.width, height: size.height - card.minY + 40)
        case .numbers: return rect(.numbers)?.insetBy(dx: -4, dy: -4)
        case .search: return rect(.search)?.insetBy(dx: -4, dy: -4)
        case .coverage: return rect(.area)?.insetBy(dx: -4, dy: -4)
        case .location: return rect(.locate)?.insetBy(dx: -4, dy: -4)
        }
    }

    @ViewBuilder
    private func stepLayer(_ step: OnboardingTour.Step, proxy: GeometryProxy) -> some View {
        let size = proxy.size
        let lit = hole(step, proxy: proxy)
        // With the card pulled up there is nothing to dim: the reader is reading it.
        let dims = !(step == .card && tour.cardOpened)
        ZStack(alignment: .topLeading) {
            if dims {
                let shape = TourDim(hole: lit, radius: step == .card ? Brand.sheetCorner : 12)
                shape
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    // Taps on the dim stop here. Taps inside the lit area reach the real app.
                    .contentShape(shape, eoFill: true)
                    .onTapGesture {}
                    .accessibilityHidden(true)
                if let lit, step != .card {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: lit.width, height: lit.height)
                        .offset(x: lit.minX, y: lit.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            caption(step)
                .frame(width: size.width - 32)
                .modifier(CaptionPlacement(edge: captionEdge(step),
                                           y: captionY(step, lit: lit, card: anchors[.card].map { proxy[$0] },
                                                       size: size),
                                           size: size))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private enum Edge { case top, bottom }

    /// Which edge of the caption is pinned: its top below a lit control near the top of the
    /// screen, its bottom above anything lower down.
    private func captionEdge(_ step: OnboardingTour.Step) -> Edge {
        switch step {
        case .tap, .numbers, .search, .coverage: .top
        default: .bottom
        }
    }

    private func captionY(_ step: OnboardingTour.Step, lit: CGRect?, card: CGRect?, size: CGSize) -> CGFloat {
        let floor = size.height - max(insets.bottom, 12) - 8
        switch step {
        case .welcome: return 0
        // Over the dimmed card from its top edge, so no half-hidden card text shows above it,
        // and clear of the map the reader is about to tap.
        case .tap: return (card?.minY ?? size.height - 220) + 12
        case .card: return tour.cardOpened ? floor : (lit.map { $0.minY - 14 } ?? floor)
        case .numbers, .search, .coverage: return (lit?.maxY ?? insets.top + 60) + 14
        case .location: return (lit?.minY ?? floor) - 14
        }
    }

    private struct CaptionPlacement: ViewModifier {
        let edge: Edge
        let y: CGFloat
        let size: CGSize
        func body(content: Content) -> some View {
            switch edge {
            case .top:
                content.fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, height: max(0, size.height - y), alignment: .top)
                    .offset(y: y)
            case .bottom:
                content.fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, height: max(0, y), alignment: .bottom)
            }
        }
    }

    private func instruction(_ step: OnboardingTour.Step) -> String {
        switch step {
        case .welcome: ""
        case .tap: "Tap anywhere on the map to pick a precinct."
        case .card: tour.cardOpened ? "Swipe the card back down to return to the map." : "Swipe the card up to see the full profile."
        case .numbers: "Tap the chart to compare every precinct here."
        case .search: "Tap the magnifying glass to find any address or place."
        case .coverage: "Start by picking the state or area you want to explore."
        case .location: locationAuthorized ? "Tap the arrow to jump back to your own precinct."
            : "Tap the arrow to see your own precinct. It's optional."
        }
    }

    /// Label for the VoiceOver-only button that does the step for the reader.
    private func voiceOverAction(_ step: OnboardingTour.Step) -> String? {
        switch step {
        case .tap: "Select the precinct in the middle of the map"
        case .card: tour.cardOpened ? "Collapse the card" : "Expand the card"
        case .numbers: "Open By the Numbers"
        case .search: "Open search"
        case .location: "Show my precinct"
        case .welcome, .coverage: nil
        }
    }

    private func caption(_ step: OnboardingTour.Step) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let position = tour.position {
                    Text("Step \(position.index) of \(position.count)")
                        .font(.bt(.footnote)).foregroundStyle(.secondary)
                }
                Text(instruction(step))
                    .font(.bt(.title3, .bold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($captionFocused)
            .accessibilityIdentifier("Tour caption")
            if voiceOver, let action = voiceOverAction(step) {
                Button { perform(step) } label: {
                    Text(action)
                        .font(.bt(.subheadline, .semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 36)
                        .background(Color(.tertiarySystemFill), in: Brand.chipShape)
                }
                .buttonStyle(.plain)
            }
            // "Skip step" moves on without doing the step. "End tour" leaves it. The last step has only
            // "Not now", since moving on and leaving are the same thing there.
            if step == .location {
                HStack { Spacer(minLength: 0); skipButton(step) }
            } else {
                // Side by side when they fit, stacked at the largest text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        endButton
                        Spacer(minLength: 8)
                        skipButton(step)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        skipButton(step)
                        endButton
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.captionSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The instruction scales with the reader's text size. Past this size the caption would
        // cover the control it points at.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear { focusCaption() }
        .onChange(of: tour.step) { focusCaption() }
        .onChange(of: tour.cardOpened) { focusCaption() }
    }

    /// White in light mode. In dark mode the elevated system gray, so the card stands off the
    /// dimmed dark map instead of melting into it.
    private static let captionSurface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? .secondarySystemBackground : .systemBackground })

    private var endButton: some View {
        Button("End tour") { tour.skipAll() }
            .font(.bt(.subheadline))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func skipButton(_ step: OnboardingTour.Step) -> some View {
        Button {
            if step == .location { tour.declineLocation() } else { tour.next() }
        } label: {
            Text(step == .location ? "Not now" : step == .coverage ? "Keep \(areaName)" : "Skip step")
                .font(.bt(.subheadline, .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Color(.tertiarySystemFill), in: Brand.chipShape)
        }
        .buttonStyle(.plain)
    }

    private func focusCaption() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            captionFocused = true
        }
    }
}

/// The tour's caption inside a sheet. By the Numbers and Search cover the map, and with it the
/// tour layer, so without this the reader would not know what the step wants or how to go on.
struct TourSheetGuide: View {
    @ObservedObject var tour = OnboardingTour.shared
    let step: OnboardingTour.Step
    let text: String
    let continueTitle: String
    /// Filled when the button is the way on ("Continue"). A gray chip when it skips, the same as
    /// "Skip step" on the map captions.
    var prominent = true
    /// Closes the sheet. Continue and End tour both close it.
    let close: () -> Void
    /// Extra work before closing, such as moving past a step the close alone does not finish.
    var beforeContinue: () -> Void = {}

    var body: some View {
        if tour.step == step {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let position = tour.position {
                        Text("Step \(position.index) of \(position.count)")
                            .font(.bt(.footnote)).foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.bt(.headline, .semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("Tour sheet caption")
                HStack(spacing: 12) {
                    Button("End tour") { tour.skipAll(); close() }
                        .font(.bt(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { beforeContinue(); close() } label: {
                        Text(continueTitle)
                            .font(.bt(.subheadline, .semibold))
                            .foregroundStyle(prominent ? Brand.surface : Color.primary)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(prominent ? Color.primary : Color(.tertiarySystemFill), in: Brand.chipShape)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground }),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Full-screen dim with one rounded cutout.
private struct TourDim: Shape {
    var hole: CGRect?
    var radius: CGFloat
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            let h = hole ?? .zero
            return AnimatablePair(AnimatablePair(h.minX, h.minY), AnimatablePair(h.width, h.height))
        }
        set {
            guard hole != nil else { return }
            hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

// MARK: - Welcome

/// The one full-screen moment: the app mark and one line about the app, ink on the page color.
private struct TourWelcome: View {
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Brand.surface.ignoresSafeArea()
            ViewThatFits(in: .vertical) {
                content(fill: true)
                ScrollView { content(fill: false) }.scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func content(fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if fill { Spacer(minLength: 24) }
            BrandMark(size: 76)
                .accessibilityHidden(true)
            Text("Precinctly")
                .brandScaledDisplay(40, .heavy)
                .foregroundStyle(Color.primary)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text("See how any precinct votes and who lives there.")
                .font(.bt(.title3))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if fill { Spacer(minLength: 32) } else { Color.clear.frame(height: 40) }
            Button(action: onStart) {
                Text("Show me around")
                    .font(.bt(.headline, .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.surface)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.primary, in: Brand.buttonShape)
            }
            .buttonStyle(.plain)
            Button(action: onSkip) {
                Text("Skip the tour")
                    .font(.bt(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
