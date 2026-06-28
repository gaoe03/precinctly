import Foundation
import CoreLocation
import MapKit
import WidgetKit
import UIKit
import PrecinctKit

/// A loaded state the user can switch between (each is its own "view").
struct AppState: Identifiable {
    let abbr: String; let name: String; let lat: Double; let lon: Double
    var id: String { abbr }
}
let appStates: [AppState] = [
    .init(abbr: "CA", name: "California",     lat: 34.050, lon: -118.243),  // Downtown LA
    .init(abbr: "MA", name: "Massachusetts",  lat: 42.360, lon: -71.058),   // Boston
    .init(abbr: "NY", name: "New York",       lat: 40.758, lon: -73.985),   // Times Square
    .init(abbr: "TX", name: "Texas",          lat: 29.760, lon: -95.370),   // Houston
]
func stateName(_ abbr: String) -> String { appStates.first { $0.abbr == abbr }?.name ?? abbr }

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
    @Published var selectedRings: [[CLLocationCoordinate2D]] = []
    @Published var neighborPins: [PrecinctPin] = []
    @Published var presidentTrend: [ElectionResult] = []   // president Dem two-party share over time
    @Published var stateBaseline: Baseline?
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
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: locationDenied = false; beginUpdates()
        case .denied, .restricted: locationDenied = true; myCoord = nil
        @unknown default: break
        }
        if selection == nil {                     // keep the map alive before any fix
            let st = appStates.first { $0.abbr == selectedState } ?? appStates[0]
            if let hit = PrecinctDB.shared.lookup(lon: st.lon, lat: st.lat) {
                selectionSource = .initial         // default state's main city; a GPS fix may take over
                loadDetails(hit.profile, rings: hit.rings,
                            at: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
            }
        }
    }

    /// "Locate me" button: jump the selection + camera back to the user's GPS precinct,
    /// even after they've tapped around (which pins selectionSource = .tap).
    func recenterOnMe() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationDenied = false
            selectionSource = .gps              // let GPS override a prior .tap selection
            if let c = myCoord { selectByGPS(c) } else { beginUpdates() }
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationDenied = true               // re-trigger the "Location is off" alert
        @unknown default:
            break
        }
    }

    private func beginUpdates() {
        manager.requestLocation()
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Map tap / neighborhood picker. Does NOT touch the widget cache, and pins
    /// the selection so a later background GPS fix won't yank the user away.
    func selectByTap(lat: Double, lon: Double) {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard let hit = PrecinctDB.shared.lookup(lon: lon, lat: lat) else {
            tap(0.4)   // soft "nothing here" cue
            toast = "No precinct here — tap on land"
            return
        }
        let p = hit.profile
        if p.state != selectedState {
            tap(0.4)
            toast = "Outside \(stateName(selectedState)) — that's in \(stateName(p.state)). Switch states from the menu."
            return
        }
        selectionSource = .tap
        tap()
        loadDetails(p, rings: hit.rings, at: coord)
    }

    /// Switch the whole view to another state and land on its main city.
    func switchState(_ abbr: String) {
        guard let st = appStates.first(where: { $0.abbr == abbr }) else { return }
        selectedState = abbr
        selectionSource = .tap
        if let hit = PrecinctDB.shared.lookup(lon: st.lon, lat: st.lat) {
            loadDetails(hit.profile, rings: hit.rings,
                        at: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
        }
    }

    private func selectByGPS(_ coord: CLLocationCoordinate2D) {
        myCoord = coord                            // the "you" pin always tracks GPS
        guard let hit = PrecinctDB.shared.lookup(lon: coord.longitude, lat: coord.latitude) else { return }
        let p = hit.profile
        ProfileStore.save(p)                       // widget always reflects where you ARE
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctLockWidget")
        guard selectionSource != .tap else { return }  // don't interrupt active exploration
        selectionSource = .gps
        if appStates.contains(where: { $0.abbr == p.state }) { selectedState = p.state }
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
        stateBaseline = PrecinctDB.shared.baseline(scope: p.state)
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
        // Tint the whole surrounding county. Cached by county so panning/zooming within it
        // never reloads — only selecting a precinct in a *different* county refetches.
        let countyKey = "\(p.state)|\(p.borough)"   // county names repeat across states (Suffolk NY vs MA)
        if countyKey != loadedCounty {
            loadedCounty = countyKey
            // The whole county, dissolved into ≈5 lean regions (Solid Rep…Solid Dem) — a handful
            // of polygons instead of thousands, so the always-on county tint stays smooth even in
            // LA (~3,000 precincts). Decoded off-main below; newest county wins.
            let rows = PrecinctDB.shared.countyLeanRegions(state: p.state, county: p.borough)
            Task.detached(priority: .userInitiated) { [weak self] in
                let pins = PrecinctDB.makePins(rows)
                // Hold the tint until the zoom-to-precinct fly has settled. Rendering hundreds of
                // polygons mid-animation makes both the fly and the tap feel laggy; this lets the
                // sheet + selected shape paint instantly and the tint arrive a beat later.
                try? await Task.sleep(nanoseconds: 280_000_000)
                await MainActor.run {
                    guard let self, self.loadedCounty == countyKey else { return }   // a newer county won the race
                    self.neighborPins = pins
                }
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
            beginUpdates()
        case .denied, .restricted:
            locationDenied = true
            myCoord = nil                    // don't leave a stale "you" pin
        default:
            break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        selectByGPS(loc.coordinate)
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
