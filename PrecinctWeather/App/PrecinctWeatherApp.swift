import SwiftUI
import UIKit

@main
struct PrecinctWeatherApp: App {
    @StateObject private var model = LocationModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Settings → Appearance: "light" / "dark" force a scheme, "auto" follows the system.
    /// Applied via UIWindow.overrideUserInterfaceStyle, not preferredColorScheme: the
    /// SwiftUI modifier can't reliably RETURN to system (nil keeps the last forced scheme),
    /// and the window override also covers sheets, covers, and alerts consistently.
    @AppStorage("appearanceMode") private var appearanceMode = "auto"

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(model)   // ContentView's own .onAppear calls model.start()
                .onAppear { Self.applyAppearance(appearanceMode) }
                .onChange(of: appearanceMode) { Self.applyAppearance(appearanceMode) }
                .onChange(of: scenePhase) {
                    if scenePhase == .active { model.resumeLocationUpdates() }
                    if scenePhase == .background { model.suspendLocationUpdates() }
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboardingPrototype") {
            NativeOnboardingPrototype()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    private static func applyAppearance(_ mode: String) {
        let style: UIUserInterfaceStyle
        switch mode {
        case "light": style = .light
        case "dark": style = .dark
        default: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
