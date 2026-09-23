import WidgetKit
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
    /// Set when the 2.0 tour finishes. People updating from 1.x have `hasOnboarded` but not this,
    /// so they see the tour once. Later updates find it set and skip the tour.
    @AppStorage("sawTour") private var sawTour = false
    private var tourDue: Bool {
        if !hasOnboarded { return true }
        // A launch that sets hasOnboarded explicitly (tests, screenshot capture) decides alone.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["hasOnboarded"] != nil { return false }
        return !sawTour
    }
    @AppStorage("defaultState") private var defaultState = "NY"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibleMapRegion: MKCoordinateRegion?
    // Map gestures stay dead during onboarding AND for a beat after dismissal: a double-tap
    // on "Start exploring" otherwise lands its second tap on the map, selects a random
    // precinct, and cancels the post-permission GPS recenter.
    @State private var mapGesturesArmed = false
    @ObservedObject private var tour = OnboardingTour.shared
    /// Only the welcome screen hides the app from VoiceOver. During the steps the real
    /// controls stay reachable so the reader can use them.
    private var tourCoversApp: Bool { tour.step == .welcome }

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
                visibleRegion: $visibleMapRegion,
                onSelectionFlightEnded: finishSelectionFlight
            )
        }
        .accessibilityHidden(expanded || tourCoversApp)
        .overlay(alignment: .bottomTrailing) {
            locateControl.padding(.trailing, 12)
                .padding(.bottom, BottomPanel.peekHeight(for: dynamicTypeSize) + 12)
                .accessibilityHidden(expanded || tourCoversApp)
        }
        .onAppear {
            if model.selection == nil { camera = .region(initialRegion(for: model.selectedState)) }
            // First run: the tour explains the app BEFORE the location permission dialog,
            // so start() (which triggers the prompt) waits for the tour to end.
            if tourDue {
                if !tour.isActive { tour.start(replay: false) }
                seedTourCamera()
            } else {
                mapGesturesArmed = true
                #if DEBUG
                if !ProcessInfo.processInfo.arguments.contains("-disableLocation") { model.start() }
                #else
                model.start()
                #endif
            }
        }
        .onChange(of: model.selectionRevision) {
            if let r = model.selectionRegion {
                beginSelectionFlight(to: r)
            }
            if tour.step == .tap { tour.next() }
        }
        .onChange(of: tour.step) { tourStepChanged() }
        .onChange(of: expanded) {
            guard tour.step == .card else { return }
            if expanded { tour.cardOpened = true } else if tour.cardOpened { tour.next() }
        }
        .onChange(of: model.showFunFacts) {
            guard tour.step == .numbers else { return }
            if model.showFunFacts { tour.numbersOpened = true } else if tour.numbersOpened { tour.next() }
        }
        .onChange(of: model.showSearch) {
            guard tour.step == .search else { return }
            if model.showSearch {
                tour.searchOpenedAt = model.selectionRevision
            } else if let opened = tour.searchOpenedAt, opened != model.selectionRevision {
                tour.next()
            } else {
                tour.searchOpenedAt = nil
            }
        }
        .onChange(of: model.locationRevision) {
            guard model.isFollowingLocation, !selectionFlightActive,
                  let coordinate = model.myCoord, let region = visibleMapRegion else { return }
            let target = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: coordinate.latitude - region.span.latitudeDelta * 0.13,
                                               longitude: coordinate.longitude),
                span: region.span
            )
            withAnimation(reduceMotion ? nil : .linear(duration: 0.4)) { camera = .region(target) }
        }
        .onChange(of: model.selectedState) {
            if model.selection == nil {
                camera = .region(initialRegion(for: model.selectedState))
            }
            if tour.step == .coverage { tour.next() }
        }
        .task {
            #if DEBUG   // launch-argument hooks for UI tests, self-tests and screenshot captures
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-testUnitID"), arguments.indices.contains(index + 1) {
                let unitID = arguments[index + 1]
                let loaded = model.selectByUnitID(unitID, fallbackLat: 0, fallbackLon: 0)
                print("UITEST \(loaded ? "PASS" : "FAIL"): selected exact unit \(unitID)")
            }
            if arguments.contains("-expandSheet") {   // screenshot capture
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                expanded = true
            }
            if arguments.contains("-openSettings") || arguments.contains("-openSources") {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                model.showSettings = true
            }
            if arguments.contains("-openSearch") {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                model.showSearch = true
            }
            if ProcessInfo.processInfo.arguments.contains("-searchSelfTest") {
                let cases = [
                    ("NY", "350 Fifth Avenue, New York, NY"),
                    ("CA", "1 Dr Carlton B Goodlett Place, San Francisco, CA"),
                    ("CA", "Midway City, CA"),
                    ("CO", "Denver, CO"),
                    ("CO", "Colorado Springs, CO"),
                    ("CO", "Fort Collins, CO"),
                    ("MA", "1 City Hall Square, Boston, MA"),
                    ("OR", "Portland, OR"),
                    ("OR", "Salem, OR"),
                    ("OR", "Eugene, OR"),
                    ("TX", "600 Congress Avenue, Austin, TX"),
                    ("DC", "1600 Pennsylvania Avenue NW, Washington, DC"),
                    (nil, "Liberty Bell, Philadelphia, PA")
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
                            PrecinctDB.shared.lookupForSearch(lon: $0.longitude, lat: $0.latitude)?.profile.state
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
                if let spec = nyFacts.first(where: { $0.leaderboard != nil && $0.id != "income" })?.leaderboard {
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
                let greaterWashington = db.scopeOverview(region: .dmvCore)
                check("DMV overview covers 1310 precincts (got \(greaterWashington.precinctCount))", greaterWashington.precinctCount == 1310)
                check("DMV population is present", (greaterWashington.totalPopulation ?? 0) > 5_000_000)
                check("DMV lean distribution is present", !greaterWashington.leanBuckets.isEmpty)
                let dmvFacts = db.funFacts(region: .dmvCore)
                check("DMV facts cover all categories (got \(dmvFacts.count))", Set(dmvFacts.map(\.category)) == Set(FactCategory.allCases))
                if let dmvSpec = dmvFacts.first(where: { $0.leaderboard != nil })?.leaderboard {
                    let dmvRows = db.topPrecincts(dmvSpec)
                    check("DMV leaderboard is populated (got \(dmvRows.count))", !dmvRows.isEmpty)
                    check("DMV leaderboard rows stay in region", dmvRows.allSatisfy { db.precinct(unitID: $0.id).map { CoverageRegion.dmvCore.contains($0.profile) } ?? false })
                }
                for state in ["DC", "MD", "VA"] {
                    let stateOverview = db.scopeOverview(state: state)
                    check("\(state) By the Numbers overview is populated", stateOverview.precinctCount > 0 && stateOverview.totalPopulation != nil)
                    check("\(state) facts are populated", !db.funFacts(state: state).isEmpty)
                }
                let caFacts = db.funFacts(state: "CA")
                check("CA facts (got \(caFacts.count))", caFacts.count > 10)
                check("CA crossover absent", !caFacts.contains { $0.id == "crossover" })
                let expansionStates: [(state: String, precincts: Int, counties: Int, normalUnit: String, year: Int, nullUnits: [String])] = [
                    ("OR", 1_300, 36, "41001-:-0001", 2020,
                     ["41005-:-X000", "41027-:-XXXX", "41045-:-0019"]),
                    ("CO", 3_163, 64, "08001-:-4215601243", 2024,
                     ["08005-:-6276103288", "08005-:-4276103350", "08005-:-6283603359", "08035-:-4303918103"]),
                ]
                for expansion in expansionStates {
                    let overview = db.scopeOverview(state: expansion.state)
                    check("\(expansion.state) precinct count \(expansion.precincts) (got \(overview.precinctCount))",
                          overview.precinctCount == expansion.precincts)
                    check("\(expansion.state) county count \(expansion.counties)",
                          db.counties(state: expansion.state).count == expansion.counties)
                    check("\(expansion.state) By the Numbers overview is populated",
                          overview.totalPopulation != nil && !overview.leanBuckets.isEmpty)
                    let facts = db.funFacts(state: expansion.state)
                    check("\(expansion.state) facts cover all categories",
                          Set(facts.map(\.category)) == Set(FactCategory.allCases))
                    check("\(expansion.state) normal profile uses its own election year",
                          db.precinct(unitID: expansion.normalUnit)?.profile.leanYear == expansion.year)
                    let nullProfiles = expansion.nullUnits.compactMap { db.precinct(unitID: $0)?.profile }
                    check("\(expansion.state) election-null profiles remain addressable",
                          nullProfiles.count == expansion.nullUnits.count)
                    check("\(expansion.state) election-null profiles keep demographics",
                          nullProfiles.allSatisfy { $0.popTotal != nil && !$0.raceBreakdown.isEmpty })
                    check("\(expansion.state) election-null profiles have no politics",
                          nullProfiles.allSatisfy {
                              $0.leanDemShare == nil && $0.leanYear == nil && $0.leanVotes == nil
                                  && db.electionSeries(unitID: $0.unitID).isEmpty
                          })
                    let nullIDs = Set(expansion.nullUnits)
                    let politicalFactsExcludeNulls = facts.filter { $0.category == .politics }.allSatisfy { fact in
                        guard !nullIDs.contains(fact.unitID ?? "") else { return false }
                        guard let specification = fact.leaderboard else { return true }
                        return db.topPrecincts(specification).allSatisfy { !nullIDs.contains($0.id) }
                    }
                    check("\(expansion.state) political facts and rankings exclude null profiles",
                          politicalFactsExcludeNulls)
                }
                // The By the Numbers charts as they ship: every metric's distribution, both ends
                // of its ranking, ties on the top value and the shift years, per area.
                for area in ["NY", "CA", "OR", CoverageRegion.dmvCore.id] {
                    let prefixes = coverageRegion(area).map { $0.isAggregate ? $0.jurisdictions.map(\.code) : [] } ?? []
                    for metric in Metric.allCases {
                        let name = "\(area) \(metric.rawValue)"
                        let dist = db.distribution(metric, state: area, county: nil, prefixes: prefixes, selectedUnitID: nil)
                        check("\(name) counts sum to total \(dist.total)", dist.counts.reduce(0, +) == dist.total)
                        if area == "CA" && metric == .turnout {
                            check("\(name) total is 0 by design (got \(dist.total))", dist.total == 0)
                        } else {
                            check("\(name) total is positive (got \(dist.total))", dist.total > 0)
                        }
                        guard dist.total > 0 else { continue }
                        let highest = db.ranked(metric, state: area, county: nil, prefixes: prefixes, bucket: nil, ascending: false, limit: 3)
                        let lowest = db.ranked(metric, state: area, county: nil, prefixes: prefixes, bucket: nil, ascending: true, limit: 3)
                        check("\(name) highest ranking non-empty (got \(highest.count))", !highest.isEmpty)
                        check("\(name) lowest ranking non-empty (got \(lowest.count))", !lowest.isEmpty)
                        // The page skips ties for the largest group, whose column is a group name.
                        if metric != .largestGroup, let top = highest.first?.value {
                            let ties = db.tieCount(metric, value: top, state: area, county: nil, prefixes: prefixes)
                            check("\(name) tie count on the top value includes it (got \(ties))", ties >= 1)
                        }
                    }
                    let years = db.shiftYears(state: area, county: nil, prefixes: prefixes)
                    check("\(area) shift years present (got \(years.count) pairs)",
                          !years.isEmpty && years.allSatisfy { $0.count > 0 })
                }
                let queens1322 = "36081-:-36081001322"
                let nyLean = db.distribution(.lean, state: "NY", county: nil, selectedUnitID: queens1322)
                check("NY lean marks \(queens1322) (bucket \(nyLean.selectedBucket.map(String.init) ?? "none"))",
                      nyLean.selectedBucket != nil)
                print(fails == 0 ? "SELFTEST ALL PASS" : "SELFTEST \(fails) FAILURES")
                return
            }
            if ProcessInfo.processInfo.arguments.contains("-liveByNumbers") {   // present the live page so its REAL status bar can be composited onto the export
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // wait out the launch-time selection flow, which would otherwise dismiss the cover
                model.showFunFacts = true
                return
            }
            if let i = arguments.firstIndex(of: "-exportWidgets"), arguments.indices.contains(i + 1) {
                // Renders the real widget views to PNGs in light and dark, for marketing captures.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let p = model.selection else { print("EXPORT widgets FAIL no selection"); return }
                let trend = PrecinctDB.shared.electionSeries(unitID: p.unitID)
                    .filter { $0.office == "president" && $0.demShare != nil }.sorted { $0.year < $1.year }
                var shift: Int?, since: Int?
                if let a = trend.first, let b = trend.last, a.year != b.year, let x = a.demShare, let y = b.demShare {
                    shift = Int(((y - x) * 200).rounded()); since = a.year
                }
                let entry = PrecinctEntry(date: Date(), profile: p, trend: trend,
                                          baseline: PrecinctDB.shared.comparisonAreas(for: p).first,
                                          shiftPts: shift, shiftSinceYear: since)
                let dir = URL(fileURLWithPath: arguments[i + 1])
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let sizes: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, CGSize(width: 170, height: 170)),
                                                               ("medium", .systemMedium, CGSize(width: 364, height: 170)),
                                                               ("large", .systemLarge, CGSize(width: 364, height: 382))]
                for scheme in [ColorScheme.light, .dark] {
                    for (name, fam, size) in sizes {
                        let view = PrecinctHomeView(entry: entry, familyOverride: fam)
                            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                            .frame(width: size.width, height: size.height)
                            .background(WidgetColor.mapTone)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .environment(\.colorScheme, scheme)
                        let r = ImageRenderer(content: view)
                        r.scale = 3
                        if let data = r.uiImage?.pngData() {
                            let url = dir.appendingPathComponent("widget-\(name)-\(scheme == .dark ? "dark" : "light").png")
                            try? data.write(to: url)
                            print("EXPORT widget \(url.path)")
                        }
                    }
                }
                return
            }
            #endif
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topControls.tourTarget(.topBar)
                if let toast = model.toast { toastView(toast) }
            }
            .padding(.top, 8).padding(.horizontal, 12)
            .accessibilityHidden(expanded || tourCoversApp)
        }
        .overlay(alignment: .bottom) {
            BottomPanel(expanded: $expanded).environmentObject(model)
                .accessibilityHidden(tourCoversApp)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            // UI tests read the settled camera here to tell a pan from a zoom.
            if ProcessInfo.processInfo.arguments.contains("-exposeMapCamera"), let r = visibleMapRegion {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("Map camera")
                    .accessibilityLabel("Map camera")
                    .accessibilityValue(String(format: "%.6f,%.6f,%.6f,%.6f", r.center.latitude, r.center.longitude,
                                               r.span.latitudeDelta, r.span.longitudeDelta))
            }
        }
        #endif
        // A plain overlay, not a cover: presenting from the first frame raced the presentation
        // machinery (and the permission dialog) and could never appear. It reads the frames of
        // the real controls so the tour can light them up where they are.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if tour.isActive, !model.showSearch, !model.showFunFacts, !model.showSettings {
                TourLayer(tour: tour, anchors: anchors,
                          locationAuthorized: [.authorizedWhenInUse, .authorizedAlways]
                            .contains(CLLocationManager().authorizationStatus),
                          areaName: stateName(model.selectedState),
                          perform: performTourStep,
                          onBegin: beginTour)
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
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(a11y)
    }

    // One chrome for every floating map control: the page color on an 8 pt rounded rectangle,
    // a hairline and a soft shadow. Opaque, so a saturated county under it never muddies it.
    private func controlChrome<V: View>(_ content: V) -> some View {
        content
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }

    private var searchControl: some View {
        controlChrome(controlIcon("magnifyingglass", "Search addresses and places") { model.showSearch = true }
            .tourTarget(.search))
    }

    private var actionControls: some View {
        controlChrome(
            HStack(spacing: 1) {
                controlIcon("chart.bar", "By the numbers") { model.showFunFacts = true }
                    .tourTarget(.numbers)
                Divider().frame(height: 30)
                controlIcon("gearshape", "Settings") { model.showSettings = true }
            }
        )
    }

    private var locateControl: some View {
        controlChrome(controlIcon(model.isFollowingLocation ? "location.fill" : "location", "Locate me") {
            model.recenterOnMe()
            if tour.step == .location { tour.next() }
        })
            .accessibilityValue(model.isFollowingLocation ? "Following your location" : "Explore map")
            .tourTarget(.locate)
    }

    @ViewBuilder
    private var topControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    searchControl
                    Spacer(minLength: 12)
                    actionControls
                }
                controlChrome(stateSelector)
            }
        } else {
            // One place bar (search plus the state it searches) on the leading edge, one action
            // group on the trailing edge. Two objects, same height, same radius.
            HStack(spacing: 10) {
                controlChrome(
                    HStack(spacing: 0) {
                        controlIcon("magnifyingglass", "Search addresses and places") { model.showSearch = true }
                            .tourTarget(.search)
                        Divider().frame(height: 26)
                        stateSelector.padding(.trailing, 4)
                    }
                )
                Spacer(minLength: 8)
                actionControls
            }
            .frame(height: 44)
        }
    }

    private var stateSelector: some View {
        Menu {
            ForEach(appStates) { st in
                Button {
                    model.switchState(st.abbr)
                } label: {
                    if model.selectedState == st.abbr {
                        Label(st.name, systemImage: "checkmark")
                    } else {
                        Text(st.name)
                    }
                }
            }
            Divider()
            Button("More coverage areas soon") {}.disabled(true)
        } label: {
            // The label sizes to the area name, so "Texas" is short and "Massachusetts" is long.
            HStack(spacing: 5) {
                Text(stateName(model.selectedState)).font(.bt(.subheadline, .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.down").font(.bt(.caption2, .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(height: 44)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Switch coverage area, currently \(stateName(model.selectedState))")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .tourTarget(.area)
    }

    // MARK: Tour

    private var locationDisabledForDebug: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-disableLocation")
        #else
        false
        #endif
    }

    /// Welcome dismissed: arm the map a beat later so a double tap on the button can't land
    /// its second tap on the map.
    private func beginTour() {
        tour.begin()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            mapGesturesArmed = true
        }
    }

    private func tourStepChanged() {
        guard let step = tour.step else {
            finishTour()
            return
        }
        switch step {
        case .welcome:
            mapGesturesArmed = false
            seedTourCamera()
            fallthrough
        case .tap, .numbers, .search, .coverage, .location:
            // Every step after the card needs the map and its controls in view.
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { expanded = false }
            // A new area from the coverage step opens zoomed out. Tapping one precinct needs streets.
            if step == .tap { seedTourCamera() }
        case .card:
            break
        }
    }

    private func finishTour() {
        hasOnboarded = true
        sawTour = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { expanded = false }
        mapGesturesArmed = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            mapGesturesArmed = true
        }
        // A replay never asks for location again. On first run, skipping the whole tour asks the
        // usual way. Finishing it only starts updates the reader already allowed: the Locate step
        // was their chance to ask, and "Not now" should mean not now.
        guard !tour.isReplay, !locationDisabledForDebug else { return }
        let status = CLLocationManager().authorizationStatus
        if tour.outcome == .skippedAll || status == .authorizedWhenInUse || status == .authorizedAlways {
            model.start()
        }
    }

    /// Starts the tap step close enough to read streets, over real precincts. New York opens on
    /// a Queens precinct, other areas on their main city.
    private func seedTourCamera() {
        guard model.selection == nil else { return }
        let span = MKCoordinateSpan(latitudeDelta: 0.022, longitudeDelta: 0.022)
        if model.selectedState == "NY",
           let hit = PrecinctDB.shared.precinct(unitID: "36081-:-36081001322"),
           let ring = hit.polygons.first?.exterior, !ring.isEmpty {
            let lat = ring.map(\.latitude), lon = ring.map(\.longitude)
            let center = CLLocationCoordinate2D(latitude: (lat.min()! + lat.max()!) / 2 - span.latitudeDelta * 0.13,
                                                longitude: (lon.min()! + lon.max()!) / 2)
            camera = .region(MKCoordinateRegion(center: center, span: span))
        } else if let st = appStates.first(where: { $0.abbr == model.selectedState }) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon),
                                                span: span))
        }
    }

    /// VoiceOver path through each step. It calls the same model actions as the real controls.
    private func performTourStep(_ step: OnboardingTour.Step) {
        switch step {
        case .tap:
            if let c = visibleMapRegion?.center {
                model.selectByTap(lat: c.latitude + (visibleMapRegion?.span.latitudeDelta ?? 0) * 0.13,
                                  lon: c.longitude)
            }
        case .card:
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { expanded.toggle() }
        case .numbers: model.showFunFacts = true
        case .search: model.showSearch = true
        case .location:
            model.recenterOnMe()
            tour.next()
        case .welcome, .coverage: break
        }
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
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { camera = .region(region) }
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
            .font(.bt(.caption)).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Brand.chipShape)
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
                                  span: MKCoordinateSpan(latitudeDelta: abbr == CoverageRegion.dmvCore.id ? 0.72 : 0.55,
                                                          longitudeDelta: abbr == CoverageRegion.dmvCore.id ? 0.86 : 0.55))
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
    @Binding var visibleRegion: MKCoordinateRegion?
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
                        ForEach(Array(pin.polygons.enumerated()), id: \.offset) { _, polygon in
                            MapPolygon(polygon.mapPolygon)
                                .foregroundStyle(Palette.lean(pin.demShare).opacity(0.52 * leanTintIntensity * Brand.mapFill))   // fill only — cheaper than per-precinct strokes
                        }
                    }
                }
                ForEach(Array(model.selectedPolygons.enumerated()), id: \.offset) { _, polygon in
                    // Fill only. MapKit strokes a polygon that has holes about twice as thick as
                    // one without, so the outline is drawn below as one line per ring instead.
                    MapPolygon(polygon.mapPolygon)
                        .foregroundStyle(Palette.lean(model.selection?.leanDemShare).opacity(0.62 * leanTintIntensity * Brand.mapFill))
                    ForEach(Array(([polygon.exterior] + polygon.interiors).enumerated()), id: \.offset) { _, ring in
                        MapPolyline(coordinates: ring + ring.prefix(1))
                            .stroke(Brand.mapStroke,
                                    style: StrokeStyle(lineWidth: Brand.mapStrokeWidth, lineCap: .round, lineJoin: .round))
                    }
                }
                if !showNeighbors, let c = model.selectionCoord {   // keep selection findable when zoomed out
                    Annotation("Selected precinct", coordinate: c) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.bt(.title2))
                            .foregroundStyle(Palette.lean(model.selection?.leanDemShare))
                            .background(Circle().fill(.white).padding(2))
                    }
                }
                if let c = model.myCoord {
                    // Ink, not system blue: on this map a saturated blue dot reads as
                    // "Democrat", so the you-marker wears the neutral accent instead.
                    Annotation("You", coordinate: c) {
                        ZStack {
                            Circle().fill(.white).frame(width: 18, height: 18)
                            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .accessibilityIdentifier("Current location")
                        .accessibilityLabel("You")
                        #if DEBUG
                        .accessibilityValue("\(c.latitude), \(c.longitude)")
                        #endif
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
                visibleRegion = ctx.region
                showNeighbors = ctx.region.span.latitudeDelta < 0.35   // county-level zoom or closer
                if selectionFlightActive { onSelectionFlightEnded(ctx.region) }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Helpers

extension MKCoordinateRegion {
    static let nyc = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
        span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55))
}
