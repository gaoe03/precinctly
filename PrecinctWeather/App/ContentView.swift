import SwiftUI
import MapKit
import CoreLocation
import UIKit
import PrecinctKit

// MARK: - Root: map + bottom sheet

struct ContentView: View {
    @EnvironmentObject var model: LocationModel
    @State private var camera: MapCameraPosition = .region(.nyc)
    @State private var expanded = false        // bottom panel: peek ↔ full
    @State private var showNeighbors = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("defaultState") private var defaultState = "NY"
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            // Extracted so resizing the bottom panel doesn't rebuild the map overlays.
            PrecinctMap(camera: $camera, showNeighbors: $showNeighbors, expanded: expanded)
        }
        .overlay(alignment: .topLeading) { searchControl.padding(.leading, 12).padding(.top, 8) }
        .overlay(alignment: .topTrailing) { actionControls.padding(.trailing, 12).padding(.top, 8) }
        .overlay(alignment: .bottomTrailing) {
            locateControl.padding(.trailing, 12).padding(.bottom, 202)   // float above the 190pt sheet peek
        }
        .onAppear {
            if model.selection == nil { camera = .region(initialRegion(for: defaultState)) }
            model.start()
            showOnboarding = !hasOnboarded
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingCard { hasOnboarded = true; showOnboarding = false }
                .presentationBackground(.clear)
        }
        .onChange(of: model.selection?.unitID) {
            if let r = model.selectionRegion {
                withAnimation(.easeInOut(duration: 0.25)) { camera = .region(r) }
                showNeighbors = true                          // a selection always lands zoomed-in
            }
        }
        .task {
            #if DEBUG   // export the full By-the-Numbers page to a tall PNG for the website asset
            if ProcessInfo.processInfo.arguments.contains("-liveByNumbers") {   // present the live page so its REAL status bar can be composited onto the export
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // wait out the launch-time selection flow, which would otherwise dismiss the cover
                model.showFunFacts = true
                return
            }
            guard ProcessInfo.processInfo.arguments.contains("-exportByNumbers") else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let facts = PrecinctDB.shared.funFacts(state: "NY")
            let overview = PrecinctDB.shared.scopeOverview(state: "NY")
            let renderer = ImageRenderer(content:
                ByNumbersExport(overview: overview, facts: facts, stateDisplay: "New York")
                    .environmentObject(model))
            renderer.scale = 3
            if let img = renderer.uiImage, let data = img.pngData() {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("bynumbers_export.png")
                try? data.write(to: url)
                print("EXPORT bynumbers \(Int(img.size.width))x\(Int(img.size.height)) -> \(url.path)")
            }
            #endif
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                stateSelector
                if let toast = model.toast { toastView(toast) }
            }
            .padding(.top, 6).padding(.horizontal, 64)
        }
        .overlay(alignment: .bottom) {
            BottomPanel(expanded: $expanded).environmentObject(model)
        }
        .animation(.default, value: model.toast)
        .alert("Location is off", isPresented: $model.locationDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Allow location access in Settings to center the map on where you are. You can still tap anywhere on the map to explore.")
        }
    }

    // Controls, placed intentionally: search top-leading (alone), app actions (By the Numbers +
    // Settings) top-trailing, "locate me" floating bottom-right (away from search), state center.
    private func controlIcon(_ systemName: String, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).frame(width: 44, height: 44)
        }
        .accessibilityLabel(a11y)
    }

    private func controlChrome<V: View>(_ content: V) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 3)
    }

    private var searchControl: some View {
        controlChrome(controlIcon("magnifyingglass", "Search neighborhoods") { model.showSearch = true })
    }

    private var actionControls: some View {
        controlChrome(
            HStack(spacing: 1) {
                controlIcon("chart.bar", "By the numbers") { model.showFunFacts = true }
                Divider().frame(height: 30)
                controlIcon("gearshape", "Settings") { model.showSettings = true }
            }
        )
    }

    private var locateControl: some View {
        controlChrome(controlIcon("location.fill", "Locate me") { model.recenterOnMe() })
    }

    private var stateSelector: some View {
        Menu {
            ForEach(appStates) { st in
                Button {
                    withAnimation { model.switchState(st.abbr) }
                } label: {
                    if model.selectedState == st.abbr {
                        Label(st.name, systemImage: "checkmark")
                    } else {
                        Text(st.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(stateName(model.selectedState)).font(.subheadline.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
        .accessibilityLabel("Switch state, currently \(stateName(model.selectedState))")
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.caption).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal, 30)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                withAnimation { model.toast = nil }
            }
    }

    private func initialRegion(for abbr: String) -> MKCoordinateRegion {
        let st = appStates.first { $0.abbr == abbr } ?? appStates[0]
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon),
                                  span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55))
    }
}

// MARK: - Map layer (isolated from the sheet so resizing the sheet doesn't redraw overlays)

private struct PrecinctMap: View {
    @EnvironmentObject var model: LocationModel
    @Binding var camera: MapCameraPosition
    @Binding var showNeighbors: Bool
    var expanded: Bool
    @AppStorage("colorNeighbors") private var colorNeighbors = true
    @AppStorage("leanTintIntensity") private var leanTintIntensity = 1.0

    // Drop the heavy county tint while the panel covers the map: when expanded the overlays
    // are occluded anyway, and live-blurring hundreds of polygons under the growing material
    // panel is what makes expanding feel janky.
    // County tint stays on at every zoom (no longer gated on zoom level) so the colored-county
    // view is always there. `showNeighbors` now only drives the find-my-precinct pin below.
    private var tintVisible: Bool { colorNeighbors && !expanded && !model.neighborPins.isEmpty }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
                if tintVisible {
                    ForEach(model.neighborPins) { pin in
                        if pin.id != model.selection?.unitID {
                            ForEach(Array(pin.rings.enumerated()), id: \.offset) { _, ring in
                                MapPolygon(coordinates: ring)
                                    .foregroundStyle(Palette.lean(pin.demShare).opacity(0.52 * leanTintIntensity))   // fill only — cheaper than per-precinct strokes
                            }
                        }
                    }
                }
                ForEach(Array(model.selectedRings.enumerated()), id: \.offset) { _, ring in
                    MapPolygon(coordinates: ring)
                        .foregroundStyle(Palette.lean(model.selection?.leanDemShare).opacity(0.62 * leanTintIntensity))
                        .stroke(Palette.lean(model.selection?.leanDemShare), lineWidth: 2.5)
                }
                if !showNeighbors, let c = model.selectionCoord {   // keep selection findable when zoomed out
                    Annotation("Selected precinct", coordinate: c) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.lean(model.selection?.leanDemShare))
                            .background(Circle().fill(.white).padding(2))
                    }
                }
                if let c = model.myCoord {
                    Annotation("You", coordinate: c) {
                        Image(systemName: "location.fill")
                            .font(.caption).padding(6)
                            .background(.blue, in: Circle()).foregroundStyle(.white).shadow(radius: 2)
                    }
                }
            }
            // A plain .onTapGesture on a Map waits to rule out the double-tap-to-zoom before it
            // fires (~0.3s of dead time on every tap). A *simultaneous* SpatialTapGesture is
            // recognized alongside the map's own gestures, so a single tap registers instantly.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        if let c = proxy.convert(value.location, from: .local) {
                            model.selectByTap(lat: c.latitude, lon: c.longitude)
                        }
                    }
            )
            .onMapCameraChange(frequency: .onEnd) { ctx in
                showNeighbors = ctx.region.span.latitudeDelta < 0.35   // county-level zoom or closer
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Helpers

extension Font {
    /// Built-in SF Serif ("New York") display face. No font bundling.
    static func serifDisplay(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension MKCoordinateRegion {
    static let nyc = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
        span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55))
}
