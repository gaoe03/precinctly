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
            .padding(36)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
        }
    }
}
