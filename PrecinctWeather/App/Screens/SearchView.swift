import SwiftUI
import MapKit

// MARK: - Address and place search

struct SearchView: View {
    @EnvironmentObject private var model: LocationModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearchModel()
    @State private var query = ""

    /// A curated spread across each state (boroughs/regions), not the first 8 in list order.
    private static let curatedPopular: [String: [String]] = [
        "NY": ["Times Square", "Williamsburg", "Astoria", "Harlem",
               "Riverdale", "St. George", "Flushing", "Park Slope"],
        "CA": ["San Francisco", "Downtown LA", "San Diego", "Sacramento",
               "Berkeley", "Santa Monica", "Fresno", "Irvine"],
        "MA": ["Boston", "Cambridge", "Worcester", "Springfield",
               "Quincy", "Lowell", "Salem", "Brookline"],
        "TX": ["Austin", "Downtown Houston", "Dallas", "San Antonio",
               "Fort Worth", "El Paso", "Arlington", "Corpus Christi"],
    ]

    private var popularPlaces: [Neighborhood] {
        let inState = searchPlaces.filter { $0.state == model.selectedState }
        guard let names = Self.curatedPopular[model.selectedState] else {
            return Array(inState.prefix(8))
        }
        return names.compactMap { name in inState.first { $0.name == name } }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        ForEach(popularPlaces) { place in
                            Button {
                                choose(place.lat, place.lon)
                            } label: {
                                resultLabel(title: place.name, subtitle: place.borough)
                            }
                        }
                    } header: {
                        Text("Popular places in \(stateName(model.selectedState))")
                    } footer: {
                        Text("Search any street address, landmark, city, or business above.")
                    }
                } else if search.isSearching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching Apple Maps")
                            .foregroundStyle(.secondary)
                    }
                } else if let notice = search.notice {
                    // Two distinct states: a real search failure (network) offers a retry;
                    // a valid result that's simply outside the loaded states is not an error.
                    // Hand-built (not ContentUnavailableView): embedded mid-List on iOS 26 it
                    // drops the Label icon, and the icon is what signals error vs coverage.
                    switch notice {
                    case .searchFailed:
                        noticeView(
                            icon: "wifi.exclamationmark",
                            title: "Search unavailable",
                            detail: "Address search needs an internet connection. Your current precinct and the map's bundled data still work offline."
                        ) {
                            Button("Try again") {
                                search.update(query: query, state: model.selectedState)
                            }
                            Button("Clear search") { query = "" }
                        }
                    case .outOfCoverage:
                        noticeView(
                            icon: "mappin.slash",
                            title: "Outside covered states",
                            detail: "Precinctly currently covers California, Massachusetts, New York, and Texas. Try another address, or close search to explore the map."
                        ) {
                            Button("Clear search") { query = "" }
                        }
                    }
                } else if search.suggestions.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                } else {
                    Section("Addresses and places") {
                        ForEach(search.suggestions, id: \.self) { suggestion in
                            Button {
                                Task { await choose(suggestion) }
                            } label: {
                                resultLabel(title: suggestion.title, subtitle: suggestion.subtitle)
                            }
                            .disabled(search.isResolving)
                        }
                    }
                }
            }
            .overlay {
                if search.isResolving {
                    ProgressView("Finding precinct")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Address or place"
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .navigationTitle("Find a precinct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) {
                search.update(query: query, state: model.selectedState)
            }
            .onChange(of: model.selectedState) {
                search.update(query: query, state: model.selectedState)
            }
            .onDisappear { search.cancel() }
        }
    }

    /// Full-width empty-state row: icon, title, explanation, and action links.
    private func noticeView<Actions: View>(
        icon: String, title: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) { actions() }
                .font(.body)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 12)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func resultLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Color.primary/.secondary, not the hierarchical styles: inside a List Button
            // the hierarchy resolves against the tint and rows render link-blue.
            Text(title)
                .foregroundStyle(Color.primary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    @MainActor
    private func choose(_ suggestion: MKLocalSearchCompletion) async {
        guard let resolution = await search.resolve(suggestion, state: model.selectedState),
              let item = search.consume(resolution) else { return }
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        choose(coordinate.latitude, coordinate.longitude)
    }

    private func choose(_ lat: Double, _ lon: Double) {
        if model.selectBySearch(lat: lat, lon: lon) {
            dismiss()
        } else {
            search.notice = .outOfCoverage
        }
    }
}

enum SearchNotice {
    case searchFailed     // network/MapKit failure: retry makes sense
    case outOfCoverage    // a real place, just outside the loaded states: not an error
}

private struct PlaceResolution {
    let item: MKMapItem
    let receipt: SearchResolutionGate.Receipt
}

@MainActor
private final class PlaceSearchModel: NSObject, ObservableObject {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var isSearching = false
    @Published var isResolving = false
    @Published var notice: SearchNotice?

    private var completer = MKLocalSearchCompleter()
    private var currentSearch: MKLocalSearch?
    private var resolutionGate = SearchResolutionGate()
    private var currentQuery = ""
    private var currentState = ""

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, state: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = trimmed
        cancelResolution()
        notice = nil
        guard !trimmed.isEmpty else {
            completer.queryFragment = ""
            suggestions = []
            isSearching = false
            return
        }
        if state != currentState {
            completer.cancel()
            let nextCompleter = MKLocalSearchCompleter()
            nextCompleter.delegate = self
            nextCompleter.resultTypes = [.address, .pointOfInterest]
            completer = nextCompleter
            currentState = state
        }
        completer.region = Self.region(for: state)
        completer.queryFragment = trimmed
        isSearching = true
    }

    func resolve(_ completion: MKLocalSearchCompletion, state: String) async -> PlaceResolution? {
        currentSearch?.cancel()
        let token = resolutionGate.begin()
        isResolving = true
        notice = nil

        let request = MKLocalSearch.Request(completion: completion)
        request.region = Self.region(for: state)
        request.resultTypes = [.address, .pointOfInterest]
        let localSearch = MKLocalSearch(request: request)
        currentSearch = localSearch
        defer {
            if currentSearch === localSearch { currentSearch = nil }
        }
        do {
            guard let item = try await localSearch.start().mapItems.first else {
                finishResolution(token)
                return nil
            }
            guard let receipt = resolutionGate.complete(token) else { return nil }
            // Keep the token current until SearchView consumes and applies the result on the
            // MainActor. A query change in that gap invalidates the token and rejects stale output.
            isResolving = false
            return PlaceResolution(item: item, receipt: receipt)
        } catch is CancellationError {
            finishResolution(token)
            return nil
        } catch {
            guard finishResolution(token) else { return nil }
            notice = .searchFailed
            return nil
        }
    }

    func consume(_ resolution: PlaceResolution) -> MKMapItem? {
        guard resolutionGate.consume(resolution.receipt) else { return nil }
        isResolving = false
        return resolution.item
    }

    func cancel() {
        completer.cancel()
        cancelResolution()
    }

    private func cancelResolution() {
        currentSearch?.cancel()
        currentSearch = nil
        resolutionGate.cancel()
        isResolving = false
    }

    @discardableResult
    private func finishResolution(_ token: UInt) -> Bool {
        guard resolutionGate.finish(token) else { return false }
        isResolving = false
        return true
    }

    private static func region(for state: String) -> MKCoordinateRegion {
        let place = appStates.first { $0.abbr == state } ?? appStates[0]
        let span: MKCoordinateSpan
        switch state {
        case "CA": span = .init(latitudeDelta: 10, longitudeDelta: 12)
        case "TX": span = .init(latitudeDelta: 11, longitudeDelta: 14)
        case "NY": span = .init(latitudeDelta: 5, longitudeDelta: 6)
        case "MA": span = .init(latitudeDelta: 3, longitudeDelta: 4)
        default: span = .init(latitudeDelta: 8, longitudeDelta: 8)
        }
        return MKCoordinateRegion(
            center: .init(latitude: place.lat, longitude: place.lon),
            span: span
        )
    }
}

extension PlaceSearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let query = completer.queryFragment
        let results = Array(completer.results.prefix(12))
        Task { @MainActor [weak self] in
            guard let self, self.completer === completer, self.currentQuery == query else { return }
            self.suggestions = results
            self.isSearching = false
            self.notice = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let query = completer.queryFragment
        Task { @MainActor [weak self] in
            guard let self, self.completer === completer,
                  self.currentQuery == query, !query.isEmpty else { return }
            self.suggestions = []
            self.isSearching = false
            self.notice = .searchFailed
        }
    }
}
