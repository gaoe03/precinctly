import SwiftUI
import PrecinctKit

/// One-card first-run intro. Shown until the user taps through (persisted in @AppStorage).
struct OnboardingCard: View {
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .transition(.opacity)
            // ViewThatFits: at the largest Dynamic Type sizes the card is taller than the
            // screen, so it falls back to a scroll view instead of pushing the button off.
            ViewThatFits(in: .vertical) {
                card.padding(36)
                ScrollView {
                    card.padding(36)
                }
                .scrollIndicators(.hidden)
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image("WidgetPin")
                .resizable().scaledToFit()
                .frame(width: 40, height: 48)
                .padding(.bottom, 2)
            Text("Read any precinct")
                .font(.serifDisplay(22, .bold))
            Text("Tap anywhere on the map to see its politics, who lives there, and the money. Pull the card up for the full story. \(Coverage.namesSentence) Location is optional and never leaves your phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Text("Start reading")
                    .fontWeight(.semibold)
                    // The dark-mode accent is a light periwinkle; the default white
                    // prominent-button label would wash out on it.
                    .foregroundStyle(scheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.16) : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(26)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }
}

#if DEBUG
/// Review-only route. The normal first-run flow and Release builds do not use this view.
struct NativeOnboardingPrototype: View {
    @EnvironmentObject private var model: LocationModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0
    @State private var selecting = false
    @State private var showWidget = false
    @AppStorage("prototypeOnboardingComplete") private var completed = false

    var body: some View {
        ContentView(onboardingReview: true, hideProfilePanel: stage == 0)
            .overlay(alignment: .bottom) {
                if stage == 0 {
                    introduction
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                if completed { stage = 2 }
            }
            .onChange(of: model.selectionRevision) {
                guard selecting, model.selection != nil else { return }
                selecting = false
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9)) {
                    stage = 2
                    completed = true
                }
            }
            .sheet(isPresented: $showWidget) {
                widgetGuide
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var introduction: some View {
        ViewThatFits(in: .vertical) {
            introductionContent
            ScrollView { introductionContent }
        }
    }

    private var introductionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image("WidgetPin").resizable().scaledToFit().frame(width: 27, height: 34)
                Text("Precinctly")
                    .font(.serifDisplay(26, .bold))
            }
            Text("Politics and people, precinct by precinct.")
                .font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                feature("hand.tap", "Tap the map", "See election results and who lives there.")
                feature("rectangle.bottomthird.inset.filled", "Pull up the profile", "Read more, compare with the area, or share it.")
                feature("chart.bar", "Browse By the Numbers", "Find the highs and lows across a covered area.")
            }
            Divider()
            Button {
                selecting = true
                model.showSearch = true
            } label: {
                Label("Find a place", systemImage: "magnifyingglass")
                    .foregroundStyle(scheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.16) : .white)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button {
                selecting = true
                model.recenterOnMe()
            } label: {
                Label("Use my location", systemImage: "location")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Text("Location is optional and stays on your device.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Explore the map first") {
                selecting = true
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9)) {
                    stage = 2
                    completed = true
                }
            }
            .font(.subheadline)
            Button("How to add a widget") { showWidget = true }
                .font(.subheadline)
        }
        .padding(26)
        .padding(.bottom, 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var widgetGuide: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Add a Home Screen widget")
                        .font(.serifDisplay(30, .bold))
                    Text("Add Precinctly to your Home Screen to see the precinct you're in without opening the app.")
                        .foregroundStyle(.secondary)
                    Text("On your Home Screen").font(.serifDisplay(22, .bold))
                    Divider()
                    Label("Touch and hold your Home Screen.", systemImage: "1.circle")
                    Label("Tap Edit, then Add Widget.", systemImage: "2.circle")
                    Label("Search for Precinctly and choose a size.", systemImage: "3.circle")
                    Text("iOS controls when widgets refresh.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        showWidget = false
                        completed = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { stage = 2 }
                    } label: {
                        Text("Start exploring")
                            .foregroundStyle(scheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.16) : .white)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showWidget = false }
                }
            }
        }
    }
}
#endif
