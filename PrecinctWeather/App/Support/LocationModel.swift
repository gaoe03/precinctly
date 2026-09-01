import Foundation
import CoreLocation
import MapKit
import WidgetKit
import UIKit
import PrecinctKit

/// A loaded coverage region the user can switch between (each is its own view).
struct AppState: Identifiable {
    let abbr: String; let name: String; let lat: Double; let lon: Double
    var id: String { abbr }
    init(region: CoverageRegion) {
        abbr = region.id; name = region.name
        lat = region.centerLatitude; lon = region.centerLongitude
    }
    init(abbr: String, name: String, lat: Double, lon: Double) {
        self.abbr = abbr; self.name = name; self.lat = lat; self.lon = lon
    }
}
let appStates: [AppState] = [
    .init(region: .dmvCore),
    .init(abbr: "CA", name: "California",     lat: 34.050, lon: -118.243),  // Downtown LA
    .init(abbr: "MA", name: "Massachusetts",  lat: 42.360, lon: -71.058),   // Boston
    .init(abbr: "NY", name: "New York",       lat: 40.758, lon: -73.985),   // Times Square
    .init(abbr: "TX", name: "Texas",          lat: 29.760, lon: -95.370),   // Houston
]
func stateName(_ abbr: String) -> String {
    if abbr == CoverageRegion.dmvCore.id { return CoverageRegion.dmvCore.name }
    return appStates.first { $0.abbr == abbr }?.name ?? abbr
}

func coverageRegion(_ id: String) -> CoverageRegion? {
    if id == CoverageRegion.dmvCore.id { return .dmvCore }
    guard let state = appStates.first(where: { $0.abbr == id }) else { return nil }
    return .state(id: state.abbr, name: state.name, latitude: state.lat, longitude: state.lon)
}

func selectedRegionContains(_ regionID: String, profile: PrecinctProfile) -> Bool {
    if let region = coverageRegion(regionID) { return region.contains(profile) }
    return regionID == profile.state
}

/// Owns Core Location and the current map selection.
///
/// Two distinct ideas, deliberately separated:
///  - `myCoord`  : the device's GPS position (drives the "you" pin + widget cache)
///  - `selection`: the precinct the user is *looking at* (GPS by default, or a map tap)
///
/// The widget cache is written ONLY for GPS selections, so tapping around the map
/// never changes what the home-screen widget shows.
final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var myCoord: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined

    @Published var selection: PrecinctProfile?
    @Published var selectionCoord: CLLocationCoordinate2D?
    @Published var selectionRegion: MKCoordinateRegion?
    @Published private(set) var selectionRevision = 0
    @Published var selectedRings: [[CLLocationCoordinate2D]] = []
    @Published var neighborPins: [PrecinctPin] = []
    @Published var presidentTrend: [ElectionResult] = []   // president Dem two-party share over time
    /// The baseline the "vs X" deltas are measured against. Named for history; it is whichever
    /// area the reader picked, resolved for this precinct.
    @Published var stateBaseline: Baseline?
    /// Every area this precinct could be compared against, narrowest first. Varies by precinct:
    /// a Brooklyn precinct offers Brooklyn, NYC, and NY; a rural Texas one offers only TX.
    @Published var comparisonAreas: [Baseline] = []

    /// The reader's preference, remembered across launches. It is a *preference*, not a promise:
    /// `resolvedBaseline` falls back when the chosen area doesn't exist or is too small here, and
    /// every label is drawn from the resolved baseline so it always names what it actually shows.
    var comparisonPreference: ComparisonArea {
        get { ComparisonArea(rawValue: UserDefaults.standard.string(forKey: "comparisonArea") ?? "") ?? .region }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "comparisonArea")
            if let p = selection { stateBaseline = resolvedBaseline(for: p) }
        }
    }

    func resolvedBaseline(for p: PrecinctProfile) -> Baseline? {
        let areas = comparisonAreas.isEmpty ? PrecinctDB.shared.comparisonAreas(for: p) : comparisonAreas
        if let key = comparisonPreference.scopeKey(for: p),
           let match = areas.first(where: { $0.scope == key }) {
            return match
        }
        return areas.last   // the state row, which is always present
    }
    @Published var toast: String?
    @Published var locationDenied = false
    @Published var showSearch = false
    @Published var showFunFacts = false
    @Published var showSettings = false
    @Published var selectedState = "NY"

    /// User setting (Settings → Feedback). Defaults on.
    private var hapticsEnabled: Bool { UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true }
    private func tap(_ intensity: CGFloat = 1) { if hapticsEnabled { haptics.impactOccurred(intensity: intensity) } }

    private enum SelectionSource { case initial, gps, tap }
    private var selectionSource: SelectionSource = .initial
    private var loadedCounty: String?   // which county's precincts are currently tinted
    private var countyLoadGeneration = 0 // invalidates polygon decodes from an older state switch
    private var locationServiceStarted = false
    private var didRequestInitialLocation = false
    private var hasManualNavigation = false
    private var explicitRecenterAfterAuthorization = false
    private var recenterGeneration = 0
    private var pendingRecenterGeneration: Int?
    private var recenterRetryCount = 0

    // Once-per-launch toasts; repeated location updates must not re-nag.
    private var warnedOutOfCoverage = false
    private var warnedApproximate = false
    private var warnedInaccurate = false
    private var warnedLocationFailure = false
    private var requestedFullAccuracy = false
    private var locationUnknownRetryCount = 0

    private let manager = CLLocationManager()
    private let haptics = UIImpactFeedbackGenerator(style: .soft)

    override init() {
        super.init()
        // Open to the user's chosen default state (Settings → General); a GPS fix may take over.
        if let saved = UserDefaults.standard.string(forKey: "defaultState"),
           appStates.contains(where: { $0.abbr == saved }) {
            selectedState = saved
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        haptics.prepare()
    }

    func start() {
        locationServiceStarted = true
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: locationDenied = false; beginUpdates()
        case .denied, .restricted: noteDenied(); myCoord = nil
        @unknown default: break
        }
    }

    /// "Locate me" button: jump the selection + camera back to the user's GPS precinct,
    /// even after they've tapped around (which pins selectionSource = .tap).
    func recenterOnMe() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationDenied = false
            selectionSource = .gps              // let GPS override a prior .tap selection
            armAutomaticRecenter()
            if manager.accuracyAuthorization == .reducedAccuracy {
                requestPreciseLocation()
            } else {
                manager.requestLocation()        // never reuse a stale or formerly approximate fix
            }
        case .notDetermined:
            explicitRecenterAfterAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationDenied = true               // re-trigger the "Location is off" alert
        @unknown default:
            break
        }
    }

    private func beginUpdates() {
        guard locationServiceStarted, !didRequestInitialLocation else { return }
        didRequestInitialLocation = true
        if !hasManualNavigation { armAutomaticRecenter() }
        manager.requestLocation()
    }

    private func armAutomaticRecenter() {
        recenterGeneration += 1
        pendingRecenterGeneration = recenterGeneration
        recenterRetryCount = 0
        locationUnknownRetryCount = 0
        warnedLocationFailure = false
    }

    /// Any explicit exploration wins over a slow startup GPS callback.
    func cancelAutomaticRecenter() {
        hasManualNavigation = true
        recenterGeneration += 1
        pendingRecenterGeneration = nil
        recenterRetryCount = 0
    }

    private func exhaustAutomaticRecenter() {
        recenterGeneration += 1
        pendingRecenterGeneration = nil
        recenterRetryCount = 0
    }

    private func retryAutomaticRecenterIfNeeded() {
        guard pendingRecenterGeneration != nil else { return }
        guard recenterRetryCount < 1 else {
            exhaustAutomaticRecenter()
            return
        }
        recenterRetryCount += 1
        manager.requestLocation()
    }

    /// The app is fully usable by tapping, so nag about denied location once per denial,
    /// not on every cold launch. (The locate-me button still re-triggers it on demand.)
    private func noteDenied() {
        guard !UserDefaults.standard.bool(forKey: "warnedLocationDenied") else { return }
        UserDefaults.standard.set(true, forKey: "warnedLocationDenied")
        locationDenied = true
    }

    /// Map tap / neighborhood picker. Does NOT touch the widget cache, and pins
    /// the selection so a later background GPS fix won't yank the user away.
    func selectByTap(lat: Double, lon: Double) {
        cancelAutomaticRecenter()
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard let hit = PrecinctDB.shared.lookup(lon: lon, lat: lat) else {
            tap(0.4)   // soft "nothing here" cue
            toast = "No precinct here. Tap on land."
            return
        }
        let p = hit.profile
        if !selectedRegionContains(selectedState, profile: p) {
            tap(0.4)
            toast = "Outside \(stateName(selectedState)). That's in \(stateName(p.state)). Switch coverage areas from the menu."
            return
        }
        selectionSource = .tap
        tap()
        loadDetails(p, rings: hit.rings, at: coord)
    }

    /// Address/place search is exploratory, like a map tap, but it can cross state lines.
    /// It deliberately does not update the GPS-only widget cache.
    @discardableResult
    func selectBySearch(lat: Double, lon: Double) -> Bool {
        cancelAutomaticRecenter()
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard let hit = PrecinctDB.shared.lookup(lon: lon, lat: lat) else { return false }
        let p = hit.profile
        selectedState = CoverageRegion.dmvCore.contains(p) ? CoverageRegion.dmvCore.id : p.state
        selectionSource = .tap
        tap()
        loadDetails(p, rings: hit.rings, at: coord)
        return true
    }

    /// Exact DB-row selection for ranked facts. Bounding-box centers can fall outside
    /// concave precincts, so leaderboard navigation must not re-run point lookup.
    @discardableResult
    func selectByUnitID(_ unitID: String, fallbackLat: Double, fallbackLon: Double) -> Bool {
        cancelAutomaticRecenter()
        guard let hit = PrecinctDB.shared.precinct(unitID: unitID) else { return false }
        let p = hit.profile
        selectedState = CoverageRegion.dmvCore.contains(p) ? CoverageRegion.dmvCore.id : p.state
        selectionSource = .tap
        tap()
        loadDetails(p, rings: hit.rings,
                    at: CLLocationCoordinate2D(latitude: fallbackLat, longitude: fallbackLon))
        return true
    }

    /// Switch the whole view to another state and land on its main city.
    func switchState(_ abbr: String) {
        cancelAutomaticRecenter()
        guard let st = appStates.first(where: { $0.abbr == abbr }) else { return }
        let destinationHit = abbr == CoverageRegion.dmvCore.id
            ? nil
            : PrecinctDB.shared.lookup(lon: st.lon, lat: st.lat)
        guard abbr == CoverageRegion.dmvCore.id || destinationHit != nil else { return }
        selectionSource = .tap
        // Invalidate any county decode already in flight before changing the visible scope. This
        // prevents a rapid state switch from painting an older county over the new map.
        countyLoadGeneration &+= 1
        loadedCounty = nil
        neighborPins = []
        // Aggregate regions are navigational map areas, not synthetic DB states.
        if abbr == CoverageRegion.dmvCore.id {
            // Do not leave a previously selected NY/CA/MA/TX profile visible while the map is
            // showing the aggregate DMV area.
            selection = nil
            selectionCoord = nil
            selectionRegion = nil
            selectedRings = []
            neighborPins = []
            comparisonAreas = []
            stateBaseline = nil
            presidentTrend = []
            selectedState = abbr
        } else if let hit = destinationHit {
            // Resolve and load the destination before publishing the new state. SwiftUI then
            // receives one coherent snapshot instead of briefly showing a new pill over old data.
            loadDetails(hit.profile, rings: hit.rings,
                        at: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
            selectedState = abbr
        }
    }

    private func selectByGPS(_ coord: CLLocationCoordinate2D) {
        myCoord = coord                            // the "you" pin always tracks GPS
        guard let hit = PrecinctDB.shared.lookup(lon: coord.longitude, lat: coord.latitude) else {
            // Worded so it's also true for covered-state users standing on water.
            if !warnedOutOfCoverage {
                warnedOutOfCoverage = true
                toast = "No precinct at your location. Precinctly covers \(Coverage.abbrList). Tap the map to explore."
            }
            retryAutomaticRecenterIfNeeded()
            return
        }
        let p = hit.profile
        ProfileStore.save(p)                       // widget always reflects where you ARE
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctLockWidget")
        guard let generation = pendingRecenterGeneration,
              generation == recenterGeneration else { return }
        pendingRecenterGeneration = nil
        recenterRetryCount = 0
        selectionSource = .gps
        if CoverageRegion.dmvCore.contains(p) {
            selectedState = CoverageRegion.dmvCore.id
        } else if appStates.contains(where: { $0.abbr == p.state }) {
            selectedState = p.state
        }
        loadDetails(p, rings: hit.rings, at: coord)
    }

    private func loadDetails(_ p: PrecinctProfile, rings: [[CLLocationCoordinate2D]],
                             at coord: CLLocationCoordinate2D) {
        selection = p
        selectionCoord = coord
        selectedRings = rings
        presidentTrend = PrecinctDB.shared.electionSeries(unitID: p.unitID)
            .filter { $0.office == "president" && $0.demShare != nil }
            .sorted { $0.year < $1.year }
        comparisonAreas = PrecinctDB.shared.comparisonAreas(for: p)
        stateBaseline = resolvedBaseline(for: p)
        if let bb = Self.boundingBox(of: rings) {
            let padLon = (bb.maxLon - bb.minLon) * 0.9 + 0.004
            let padLat = (bb.maxLat - bb.minLat) * 0.9 + 0.004
            let spanLat = (bb.maxLat - bb.minLat) + padLat
            // The always-present bottom sheet (~190pt peek) hides the lower third of the map, so MapKit's
            // full-frame center drops the precinct low in the *visible* window. Bias the camera south by
            // ~13% of the vertical span so the shape sits centered in the part you can actually see.
            selectionRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (bb.minLat + bb.maxLat) / 2 - spanLat * 0.13,
                                               longitude: (bb.minLon + bb.maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: spanLat,
                                       longitudeDelta: (bb.maxLon - bb.minLon) + padLon))
        }
        // A successful explicit Locate/search/tap must move the camera even when it resolves to
        // the precinct that was already selected. The unit ID alone does not change in that case.
        selectionRevision &+= 1
        // Tint the whole surrounding county. Cached by county so panning/zooming within it
        // never reloads — only selecting a precinct in a *different* county refetches.
        let countyKey = "\(p.state)|\(p.borough)"   // county names repeat across states (Suffolk NY vs MA)
        if countyKey != loadedCounty {
            loadedCounty = countyKey
            countyLoadGeneration &+= 1
            let generation = countyLoadGeneration
            neighborPins = []
            // Let the selected profile and camera paint before querying the county tint. The
            // database is main-thread-only, so the query itself cannot move off-main, but yielding
            // here prevents a large county from blocking the state switch's first frame.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.loadedCounty == countyKey,
                      self.countyLoadGeneration == generation else { return }
                // The whole county, dissolved into ≈5 lean regions (Solid Rep…Solid Dem) — a
                // handful of polygons instead of thousands, so the always-on county tint stays
                // smooth even in LA (~3,000 precincts). Decode off-main below; newest county wins.
                let rows = PrecinctDB.shared.countyLeanRegions(state: p.state, county: p.borough)
                let decodeTask = Task.detached(priority: .userInitiated) {
                    PrecinctDB.makePins(rows)
                }
                let pins = await decodeTask.value
                // Hold the tint until the zoom-to-precinct fly has settled. Rendering hundreds of
                // polygons mid-animation makes both the fly and the tap feel laggy; this lets the
                // sheet + selected shape paint instantly and the tint arrive a beat later.
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard self.loadedCounty == countyKey,
                      self.countyLoadGeneration == generation else { return } // a newer county won the race
                self.neighborPins = pins
            }
        }
    }

    /// Bounding box of already-decoded rings — avoids a second DB round-trip just for min/max.
    private static func boundingBox(of rings: [[CLLocationCoordinate2D]])
        -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)? {
        var minLon = Double.greatestFiniteMagnitude, minLat = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        var any = false
        for ring in rings {
            for c in ring {
                any = true
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
                minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            }
        }
        return any ? (minLon, minLat, maxLon, maxLat) : nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        status = m.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationDenied = false
            UserDefaults.standard.set(false, forKey: "warnedLocationDenied")   // a later revoke warns once again
            guard locationServiceStarted || explicitRecenterAfterAuthorization else { return }
            if explicitRecenterAfterAuthorization {
                explicitRecenterAfterAuthorization = false
                didRequestInitialLocation = true
                armAutomaticRecenter()
                if m.accuracyAuthorization == .reducedAccuracy {
                    requestPreciseLocation()
                } else {
                    m.requestLocation()
                }
            } else {
                beginUpdates()
            }
        case .denied, .restricted:
            explicitRecenterAfterAuthorization = false
            exhaustAutomaticRecenter()
            didRequestInitialLocation = false
            noteDenied()
            myCoord = nil                    // don't leave a stale "you" pin
        default:
            break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        locationUnknownRetryCount = 0
        warnedLocationFailure = false
        // Precise Location off fuzzes fixes to 1-5 km; precincts are a few blocks wide, so a
        // fuzzed fix would confidently select the WRONG precinct. Ask once for temporary full
        // accuracy; if it stays reduced, keep the "you" pin but don't pretend to know the precinct.
        if m.accuracyAuthorization == .reducedAccuracy {
            myCoord = loc.coordinate
            if pendingRecenterGeneration != nil { requestPreciseLocation() }
            return
        }
        let age = abs(loc.timestamp.timeIntervalSinceNow)
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100, age <= 60 else {
            myCoord = loc.coordinate
            if !warnedInaccurate {
                warnedInaccurate = true
                toast = "Your location isn't precise enough to choose a precinct yet. Try again near a window, search an address, or tap the map."
            }
            retryAutomaticRecenterIfNeeded()
            return
        }
        warnedInaccurate = false
        selectByGPS(loc.coordinate)
    }

    private func requestPreciseLocation() {
        if !requestedFullAccuracy {
            requestedFullAccuracy = true
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PrecinctLookup") { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.manager.accuracyAuthorization == .reducedAccuracy {
                        self.warnApproximate()
                        self.exhaustAutomaticRecenter()
                    }
                    else { self.manager.requestLocation() }
                }
            }
        } else {
            warnApproximate()
            exhaustAutomaticRecenter()
        }
    }

    private func warnApproximate() {
        guard !warnedApproximate else { return }
        warnedApproximate = true
        toast = "Precise Location is off, so your exact precinct can't be found. Tap the map instead."
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        guard let locationError = error as? CLError else {
            warnLocationFailure()
            return
        }
        switch locationError.code {
        case .locationUnknown where pendingRecenterGeneration != nil
            && locationUnknownRetryCount < 1:
            locationUnknownRetryCount += 1
            m.requestLocation()
        case .locationUnknown:
            exhaustAutomaticRecenter()
            warnLocationFailure()
        case .denied:
            exhaustAutomaticRecenter()
            noteDenied()
        default:
            warnLocationFailure()
        }
    }

    private func warnLocationFailure() {
        guard !warnedLocationFailure else { return }
        warnedLocationFailure = true
        toast = "Your location isn't available right now. Try again, search an address, or tap the map."
    }
}
