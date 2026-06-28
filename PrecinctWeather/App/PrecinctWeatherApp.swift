import SwiftUI

@main
struct PrecinctWeatherApp: App {
    @StateObject private var model = LocationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)   // ContentView's own .onAppear calls model.start()
        }
    }
}
