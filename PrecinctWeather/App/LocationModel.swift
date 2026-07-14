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
    /// Bumped on every (re)load so the camera flies even when re-selecting the same precinct
    /// (e.g. "locate me" after panning away). Keyed on this instead of the precinct id.
    @Published var selectionSerial = 0
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
    /// Set by an explicit locate-me press so the camera reframes even when the precinct
    /// didn't change. Everything else only flies when the selection actually moves,
    /// re-tapping your own precinct shouldn't cost an animation.
    private var forceNextReframe = false

    // Once-per-launch toasts; repeated location updates must not re-nag.
    private var warnedOutOfCoverage = false
    private var warnedApproximate = false
    private var requestedFullAccuracy = false
    /// True while the system permission prompt this session is outstanding. A denial that
    /// arrives through it gets a quiet toast, not a modal (the user just answered; don't
    /// ask again in the same breath). The modal stays for launches that start denied and
    /// for explicit locate-me presses.
    private var promptedThisSession = false
    private var sessionTapCount = 0   // successful map taps, for the one-time By-the-Numbers tip

    private let manager = CLLocationManager()
    private let haptics = UIImpactFeedbackGenerator(style: .soft)

    override init() {
        super.init()
        // Open where the last GPS fix landed (so a Houston user reopens on Texas, not Times Square);
        // fall back to the chosen default state (Settings → General). A fresh GPS fix may take over.
        if let last = UserDefaults.standard.string(forKey: "lastGeoState"),
           appStates.contains(where: { $0.abbr == last }) {
            selectedState = last
        } else if let saved = UserDefaults.standard.string(forKey: "defaultState"),
                  appStates.contains(where: { $0.abbr == saved }) {
            selectedState = saved
        } else {
            // Very first launch, before any fix or preference: guess from the time zone so a
            // Texan's or Californian's first frame is at least their own state, not Times Square.
            switch TimeZone.current.identifier {
            case "America/Chicago":     selectedState = "TX"
            case "America/Los_Angeles": selectedState = "CA"
            default: break   // Eastern (NY/MA) and everywhere else keep the NY default
            }
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        haptics.prepare()
    }

    func start() {
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: promptedThisSession = true; manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: locationDenied = false; beginUpdates()
        case .denied, .restricted: noteDenied(); myCoord = nil
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
            warnedOutOfCoverage = false         // an explicit press always gets a fresh answer
            forceNextReframe = true             // camera must respond even if the precinct is the same
            if let c = myCoord { selectByGPS(c) } else { beginUpdates() }
        case .notDetermined:
            promptedThisSession = true
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
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard let hit = PrecinctDB.shared.lookup(lon: lon, lat: lat) else {
            tap(0.4)   // soft "nothing here" cue
            // A miss NEAR precincts is water or a boundary gap; only a genuinely
            // out-of-coverage miss earns the coverage recital.
            toast = PrecinctDB.shared.hasPrecincts(nearLon: lon, lat: lat)
                ? "No precinct here. Try tapping on land."
                : "No precincts here yet. Precinct covers \(Coverage.abbrList), with more coming."
            return
        }
        let p = hit.profile
        selectionSource = .tap
        tap()
        // A DB hit is always in a covered state, so just follow the tap there instead of refusing.
        if p.state != selectedState, appStates.contains(where: { $0.abbr == p.state }) {
            selectedState = p.state
            toast = "Switched to \(stateName(p.state))."
        }
        loadDetails(p, rings: hit.rings, at: coord)
        maybeShowByNumbersTip()
    }

    /// One-time discovery nudge: after a few deliberate taps, point at the page most
    /// people never find on their own. Skipped whenever another toast is already up.
    private func maybeShowByNumbersTip() {
        sessionTapCount += 1
        guard sessionTapCount >= 3, toast == nil,
              !UserDefaults.standard.bool(forKey: "tippedByNumbers") else { return }
        UserDefaults.standard.set(true, forKey: "tippedByNumbers")
        toast = "By the Numbers ranks every precinct in the state. It's the chart button at the top right."
    }

    /// Select an exact precinct by id (from a leaderboard drill-in). Bypasses point-in-polygon so a
    /// concave precinct whose bbox center sits outside itself still resolves to the right shape.
    func selectByUnitID(_ unitID: String) {
        guard let hit = PrecinctDB.shared.lookupByUnitID(unitID),
              let bb = Self.boundingBox(of: hit.rings) else { return }
        let p = hit.profile
        selectionSource = .tap
        tap()
        if p.state != selectedState, appStates.contains(where: { $0.abbr == p.state }) {
            selectedState = p.state
            toast = "Switched to \(stateName(p.state))."   // same feedback as a cross-state tap
        }
        loadDetails(p, rings: hit.rings,
                    at: CLLocationCoordinate2D(latitude: (bb.minLat + bb.maxLat) / 2,
                                               longitude: (bb.minLon + bb.maxLon) / 2))
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
        guard let hit = PrecinctDB.shared.lookup(lon: coord.longitude, lat: coord.latitude) else {
            // Worded so it's also true for covered-state users standing on water.
            if !warnedOutOfCoverage {
                warnedOutOfCoverage = true
                toast = "No precinct at your location yet. Precinct covers \(Coverage.abbrList), with more coming. Tap the map to look around."
            }
            return
        }
        let p = hit.profile
        ProfileStore.save(p)                       // widget always reflects where you ARE
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "PrecinctLockWidget")
        if appStates.contains(where: { $0.abbr == p.state }) {
            UserDefaults.standard.set(p.state, forKey: "lastGeoState")   // open here next launch, not Times Square
        }
        guard selectionSource != .tap else { return }  // don't interrupt active exploration
        selectionSource = .gps
        if appStates.contains(where: { $0.abbr == p.state }) { selectedState = p.state }
        loadDetails(p, rings: hit.rings, at: coord)
    }

    private func loadDetails(_ p: PrecinctProfile, rings: [[CLLocationCoordinate2D]],
                             at coord: CLLocationCoordinate2D) {
        // Fly the camera only when the selection actually changes (or a locate press asked).
        // Bumping the serial on every load made each re-tap animate the camera for nothing.
        let precinctChanged = p.unitID != selection?.unitID
        selection = p
        selectionCoord = coord
        selectedRings = rings
        if precinctChanged || forceNextReframe {
            forceNextReframe = false
            selectionSerial &+= 1
        }
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
                await MainActor.run { [weak self] in
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
            promptedThisSession = false
            UserDefaults.standard.set(false, forKey: "warnedLocationDenied")   // a later revoke warns once again
            beginUpdates()
        case .denied, .restricted:
            myCoord = nil                    // don't leave a stale "you" pin
            if promptedThisSession {
                // The user just answered the system prompt; a modal here reads as asking
                // again. Acknowledge quietly and mark this denial as warned.
                promptedThisSession = false
                UserDefaults.standard.set(true, forKey: "warnedLocationDenied")
                toast = "Location is off. You can still tap anywhere on the map, or switch states from the menu at the top."
            } else {
                noteDenied()
            }
        default:
            break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        // Precise Location off fuzzes fixes to 1-5 km; precincts are a few blocks wide, so a
        // fuzzed fix would confidently select the WRONG precinct. Ask once for temporary full
        // accuracy; if it stays reduced, keep the "you" pin but don't pretend to know the precinct.
        if m.accuracyAuthorization == .reducedAccuracy {
            myCoord = loc.coordinate
            if !requestedFullAccuracy {
                requestedFullAccuracy = true
                m.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PrecinctLookup") { [weak self] _ in
                    DispatchQueue.main.async {
                        if m.accuracyAuthorization == .reducedAccuracy { self?.warnApproximate() }
                        else { m.requestLocation() }   // precise granted: get a real fix
                    }
                }
            } else {
                warnApproximate()
            }
            return
        }
        selectByGPS(loc.coordinate)
    }

    private func warnApproximate() {
        guard !warnedApproximate else { return }
        warnedApproximate = true
        toast = "Precise Location is off, so your exact precinct can't be found. Tap the map instead."
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
