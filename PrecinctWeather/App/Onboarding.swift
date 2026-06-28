import SwiftUI

/// One-card first-run intro. Shown until the user taps through (persisted in @AppStorage).
struct OnboardingCard: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .transition(.opacity)
            VStack(spacing: 14) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 38))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 2)
                Text("Read any precinct")
                    .font(.system(.title2, design: .serif).weight(.bold))
                Text("Tap anywhere on the map to see its politics, who lives there, and the money. Pull the card up for the full story — or open **By the Numbers** for a state's extremes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onDismiss) {
                    Text("Start exploring")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(36)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }
}
