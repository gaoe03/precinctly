import SwiftUI
import PrecinctKit

// MARK: - Search (offline neighborhood list)

struct SearchView: View {
    @EnvironmentObject var model: LocationModel
    @State private var query = ""

    private var places: [Neighborhood] {
        // Browsing (no query) stays in-state; a typed query searches all four states, since
        // selecting a place already switches states with a toast. "Boston" works from anywhere.
        guard !query.isEmpty else { return searchPlaces.filter { $0.state == model.selectedState } }
        return searchPlaces.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.borough.localizedCaseInsensitiveContains(query)
        }
    }
    private var precincts: [(name: String, borough: String, lat: Double, lon: Double)] {
        query.count >= 2
            ? PrecinctDB.shared.searchPrecincts(state: model.selectedState, query: query)
            : []
    }

    var body: some View {
        NavigationStack {
            List {
                if !places.isEmpty {
                    Section("Places") {
                        ForEach(places) { n in
                            Button { go(n.lat, n.lon) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.name).foregroundStyle(.primary)
                                    Text("\(n.borough), \(n.state)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !precincts.isEmpty {
                    Section("Precincts") {
                        ForEach(Array(precincts.enumerated()), id: \.offset) { _, p in
                            Button { go(p.lat, p.lon) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(precinctDisplayName(p.name)).foregroundStyle(.primary)
                                    if !p.borough.isEmpty {
                                        Text(p.borough).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if !query.isEmpty && places.isEmpty && precincts.isEmpty {
                    ContentUnavailableView {
                        Label("No results for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass")
                    } description: {
                        Text("Places match across all four states. Precinct names match within \(stateName(model.selectedState)).")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search places and precincts")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.showSearch = false }
                }
            }
        }
    }

    private func go(_ lat: Double, _ lon: Double) {
        model.selectByTap(lat: lat, lon: lon)
        model.showSearch = false
    }
}
