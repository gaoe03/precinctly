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
    @State private var selectionFlightID = 0
    @State private var selectionFlightActive = false
    @State private var selectionFlightTarget: MKCoordinateRegion?
    @State private var suppressCountyTint = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("defaultState") private var defaultState = "NY"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Map gestures stay dead during onboarding AND for a beat after dismissal: a double-tap
    // on "Start exploring" otherwise lands its second tap on the map, selects a random
    // precinct, and cancels the post-permission GPS recenter.
    @State private var mapGesturesArmed = false

    var body: some View {
        ZStack {
            // Extracted so resizing the bottom panel doesn't rebuild the map overlays.
            PrecinctMap(
                camera: $camera,
                showNeighbors: $showNeighbors,
                expanded: expanded,
                suppressCountyTint: suppressCountyTint,
                selectionFlightActive: selectionFlightActive,
                gesturesArmed: mapGesturesArmed,
                onSelectionFlightEnded: finishSelectionFlight
            )
        }
        .accessibilityHidden(expanded || !hasOnboarded)
        .overlay(alignment: .bottomTrailing) {
            locateControl.padding(.trailing, 12)
                .padding(.bottom, BottomPanel.peekHeight(for: dynamicTypeSize) + 12)
                .accessibilityHidden(expanded || !hasOnboarded)
        }
        .onAppear {
            if model.selection == nil { camera = .region(initialRegion(for: model.selectedState)) }
            // First run: onboarding explains the app BEFORE the location permission dialog,
            // so start() (which triggers the prompt) waits for the card to be dismissed.
            if hasOnboarded {
                mapGesturesArmed = true
                model.start()
            }
        }
        .onChange(of: model.selectionRevision) {
            if let r = model.selectionRegion {
                beginSelectionFlight(to: r)
            }
        }
        .task {
            #if DEBUG   // export the full By-the-Numbers page to a tall PNG for the website asset
            if ProcessInfo.processInfo.arguments.contains("-searchSelfTest") {
                let cases = [
                    ("NY", "350 Fifth Avenue, New York, NY"),
                    ("CA", "1 Dr Carlton B Goodlett Place, San Francisco, CA"),
                    ("MA", "1 City Hall Square, Boston, MA"),
                    ("TX", "600 Congress Avenue, Austin, TX"),
                    (nil, "1600 Pennsylvania Avenue NW, Washington, DC")
                ]
                var failures = 0
                for (expectedState, query) in cases {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    request.resultTypes = [.address, .pointOfInterest]
                    do {
                        let item = try await MKLocalSearch(request: request).start().mapItems.first
                        let coordinate: CLLocationCoordinate2D?
                        if #available(iOS 26.0, *) {
                            coordinate = item?.location.coordinate
                        } else {
                            coordinate = item?.placemark.coordinate
                        }
                        let state = coordinate.flatMap {
                            PrecinctDB.shared.lookup(lon: $0.longitude, lat: $0.latitude)?.profile.state
                        }
                        let passed = state == expectedState
                        print("SEARCHTEST \(passed ? "PASS" : "FAIL"): \(query) expected \(expectedState ?? "outside coverage"), got \(state ?? "outside coverage")")
                        if !passed { failures += 1 }
                    } catch {
                        print("SEARCHTEST FAIL: \(query) MapKit error \(error.localizedDescription)")
                        failures += 1
                    }
                }
                print(failures == 0 ? "SEARCHTEST ALL PASS" : "SEARCHTEST \(failures) FAILURES")
                return
            }
            if ProcessInfo.processInfo.arguments.contains("-dbSelfTest") {   // exercise every By-the-Numbers query path and print PASS/FAIL (run after DB or query changes)
                let db = PrecinctDB.shared
                var fails = 0
                func check(_ name: String, _ ok: Bool) { print("SELFTEST \(ok ? "PASS" : "FAIL"): \(name)"); if !ok { fails += 1 } }
                let ny = db.scopeOverview(state: "NY")
                check("NY precinct count 14011 (got \(ny.precinctCount))", ny.precinctCount == 14011)
                check("NY median income non-nil", ny.medianIncome != nil)
                check("NY lean buckets non-empty", !ny.leanBuckets.isEmpty)
                let bk = db.scopeOverview(state: "NY", county: "Brooklyn")
                check("Brooklyn precinct count 1731 (got \(bk.precinctCount))", bk.precinctCount == 1731)
                let nyFacts = db.funFacts(state: "NY")
                check("NY facts (got \(nyFacts.count))", nyFacts.count > 10)
                check("NY crossover present", nyFacts.contains { $0.id == "crossover" })
                let exactFactTargets = nyFacts.allSatisfy { fact in
                    guard fact.lat != nil || fact.lon != nil else { return true }
                    guard let unitID = fact.unitID else { return false }
                    return db.precinct(unitID: unitID)?.profile.unitID == unitID
                }
                check("NY fact targets resolve by exact unit ID", exactFactTargets)
                for f in nyFacts.prefix(6) { print("SELFTEST info NY: \(f.id) = \(f.value) at \(f.place)") }
                if let spec = nyFacts.first(where: { $0.leaderboard != nil })?.leaderboard {
                    let rows = db.topPrecincts(spec)
                    check("NY '\(spec.title)' leaderboard 25 rows (got \(rows.count))", rows.count == 25)
                    check("NY leaderboard targets resolve by exact unit ID", rows.allSatisfy {
                        db.precinct(unitID: $0.id)?.profile.unitID == $0.id
                    })
                }
                let bkFacts = db.funFacts(state: "NY", county: "Brooklyn")
                check("Brooklyn facts (got \(bkFacts.count))", bkFacts.count > 5)
                if let spec = bkFacts.first(where: { $0.leaderboard != nil })?.leaderboard {
                    let rows = db.topPrecincts(spec)
                    check("Brooklyn '\(spec.title)' leaderboard non-empty (got \(rows.count))", !rows.isEmpty)
                }
                let caFacts = db.funFacts(state: "CA")
                check("CA facts (got \(caFacts.count))", caFacts.count > 10)
                check("CA crossover absent", !caFacts.contains { $0.id == "crossover" })
                print(fails == 0 ? "SELFTEST ALL PASS" : "SELFTEST \(fails) FAILURES")
                return
            }
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
                topControls
                if let toast = model.toast { toastView(toast) }
            }
            .padding(.top, 8).padding(.horizontal, 12)
            .accessibilityHidden(expanded || !hasOnboarded)
        }
        .overlay(alignment: .bottom) {
            BottomPanel(expanded: $expanded).environmentObject(model)
                .accessibilityHidden(!hasOnboarded)
        }
        .overlay {
            // A plain overlay, not a cover: presenting from the first frame raced the
            // presentation machinery (and the permission dialog) and could never appear.
            if !hasOnboarded {
                OnboardingCard {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { hasOnboarded = true }
                    model.start()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        mapGesturesArmed = true
                    }
                }
            }
        }
        .animation(reduceMotion ? .none : .default, value: model.toast)
        .alert("Location is off", isPresented: $model.locationDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Allow location access in Settings to center the map on where you are. You can still tap anywhere on the map to explore.")
        }
    }

    // Controls, placed intentionally: search top-leading (alone), app actions (By the Numbers +
    // Settings) top-trailing, "locate me" floating bottom-right (away from search), state center.
    private func controlIcon(_ systemName: String, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(a11y)
    }

    // One chrome for every floating map control. They used to be three different treatments on
    // one screen: a radius-12 regularMaterial rectangle for search and the action pair, a
    // thickMaterial capsule with a hairline for the state menu, and two different shadows. Same
    // reason the state pill went near-opaque applies to all of them: a thin material picks up
    // whatever lean color sits under it and reads muddy and borderless over a saturated county.
    private func controlChrome<V: View>(_ content: V) -> some View {
        content
            .background(.thickMaterial, in: Capsule())
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private var searchControl: some View {
        controlChrome(controlIcon("magnifyingglass", "Search addresses and places") { model.showSearch = true })
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

    @ViewBuilder
    private var topControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                HStack {
                    searchControl
                    Spacer(minLength: 12)
                    actionControls
                }
                stateSelector(width: 180)
            }
        } else {
            ZStack {
                HStack {
                    searchControl
                    Spacer(minLength: 12)
                    actionControls
                }
                stateSelector(width: 126)   // fits "Massachusetts" without truncating
            }
            .frame(height: 44)
        }
    }

    private func stateSelector(width: CGFloat) -> some View {
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
            Divider()
            Button("More states soon") {}.disabled(true)
        } label: {
            controlChrome(
                HStack(spacing: 4) {
                    Text(stateName(model.selectedState)).font(.subheadline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 16)
                // Matches the 44pt icon controls so the whole top row sits on one line.
                .frame(height: 44)
            )
        }
        .accessibilityLabel("Switch state, currently \(stateName(model.selectedState))")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func beginSelectionFlight(to region: MKCoordinateRegion) {
        selectionFlightID += 1
        let flightID = selectionFlightID
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            suppressCountyTint = true
            selectionFlightActive = false
            selectionFlightTarget = region
            showNeighbors = true
        }

        Task { @MainActor in
            await Task.yield()
            guard flightID == selectionFlightID else { return }
            selectionFlightActive = true
            withAnimation(.easeInOut(duration: 0.25)) { camera = .region(region) }
            try? await Task.sleep(for: .milliseconds(600))
            guard flightID == selectionFlightID, suppressCountyTint else { return }
            selectionFlightActive = false
            suppressCountyTint = false
        }
    }

    private func finishSelectionFlight(at settledRegion: MKCoordinateRegion) {
        guard selectionFlightActive,
              let target = selectionFlightTarget,
              Self.regionsMatch(settledRegion, target) else { return }
        let flightID = selectionFlightID
        selectionFlightActive = false
        Task { @MainActor in
            await Task.yield()
            guard flightID == selectionFlightID, !selectionFlightActive else { return }
            suppressCountyTint = false
        }
    }

    private static func regionsMatch(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
        let latTolerance = max(rhs.span.latitudeDelta * 0.05, 0.0001)
        let lonTolerance = max(rhs.span.longitudeDelta * 0.05, 0.0001)
        return abs(lhs.center.latitude - rhs.center.latitude) <= latTolerance
            && abs(lhs.center.longitude - rhs.center.longitude) <= lonTolerance
            && abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) <= latTolerance
            && abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) <= lonTolerance
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.caption).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal, 30)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .onAppear {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
            .task(id: text) {
                // Reading time, not a fixed 2.4s: the coverage/accuracy notices are full
                // sentences and were gone before anyone could read them.
                let seconds = max(2.4, Double(text.count) * 0.07)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
    var suppressCountyTint: Bool
    var selectionFlightActive: Bool
    var gesturesArmed: Bool   // false during onboarding + a beat after dismissal
    var onSelectionFlightEnded: (MKCoordinateRegion) -> Void
    @AppStorage("colorNeighbors") private var colorNeighbors = true
    @AppStorage("leanTintIntensity") private var leanTintIntensity = 0.5    // soft default, must match SettingsView

    private var debugTintDisabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-disableCountyTint")
        #else
        false
        #endif
    }

    // Drop the heavy county tint while the panel covers the map: when expanded the overlays
    // are occluded anyway, and live-blurring hundreds of polygons under the growing material
    // panel is what makes expanding feel janky.
    // County tint stays on at every zoom (no longer gated on zoom level) so the colored-county
    // view is always there. `showNeighbors` now only drives the find-my-precinct pin below.
    private var tintVisible: Bool {
        colorNeighbors && !expanded && !suppressCountyTint && !debugTintDisabled
            && !model.neighborPins.isEmpty
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
                if tintVisible {
                    // No per-pin selection check: region ids never match a precinct unit_id, and
                    // referencing model.selection here made every tap re-diff all region polygons.
                    ForEach(model.neighborPins) { pin in
                        ForEach(Array(pin.rings.enumerated()), id: \.offset) { _, ring in
                            MapPolygon(coordinates: ring)
                                .foregroundStyle(Palette.lean(pin.demShare).opacity(0.52 * leanTintIntensity))   // fill only — cheaper than per-precinct strokes
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
                    // Slate ink, not system blue: on this map a saturated blue dot reads as
                    // "Democrat", so the you-marker wears the neutral accent instead.
                    Annotation("You", coordinate: c) {
                        ZStack {
                            Circle().fill(.white).frame(width: 18, height: 18)
                            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
            }
            // Muted basemap so the lean tint stays the loudest thing on screen; all POI kept
            // (shops, restaurants, parks, transit) because the map doubles as a way to orient
            // and explore. Traffic is the one layer that adds nothing here.
            .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                pointsOfInterest: .all, showsTraffic: false))
            // A plain .onTapGesture on a Map waits to rule out the double-tap-to-zoom before it
            // fires (~0.3s of dead time on every tap). A *simultaneous* SpatialTapGesture is
            // recognized alongside the map's own gestures, so a single tap registers instantly.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        guard gesturesArmed else { return }
                        if let c = proxy.convert(value.location, from: .local) {
                            model.selectByTap(lat: c.latitude, lon: c.longitude)
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in if gesturesArmed { model.cancelAutomaticRecenter() } }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { _ in if gesturesArmed { model.cancelAutomaticRecenter() } }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { _ in if gesturesArmed { model.cancelAutomaticRecenter() } }
            )
            .onMapCameraChange(frequency: .onEnd) { ctx in
                showNeighbors = ctx.region.span.latitudeDelta < 0.35   // county-level zoom or closer
                if selectionFlightActive { onSelectionFlightEnded(ctx.region) }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Helpers

extension Font {
    /// Built-in SF Serif ("New York") display face. No font bundling.
    /// `.system(size:)` fonts don't track Dynamic Type, so scale the point size with
    /// UIFontMetrics (which reads the current traits during SwiftUI body eval and re-renders on
    /// change). Capped at 1.4x so the fixed-height peek sheet can't overflow at accessibility sizes.
    /// Upgrade path: per-call-site @ScaledMetric if a screen needs the full range.
    static func serifDisplay(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let scaled = min(UIFontMetrics.default.scaledValue(for: size), size * 1.4)
        return .system(size: scaled, weight: weight, design: .serif)
    }
}

extension MKCoordinateRegion {
    static let nyc = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
        span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55))
}
