import SwiftUI
import PrecinctKit

// MARK: - Search (offline neighborhood list)

struct SearchView: View {
    @EnvironmentObject var model: LocationModel
    @State private var query = ""

    private var places: [Neighborhood] {
        let inState = searchPlaces.filter { $0.state == model.selectedState }
        guard !query.isEmpty else { return inState }
        return inState.filter {
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
                Section("Places") {
                    ForEach(places) { n in
                        Button { go(n.lat, n.lon) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.name).foregroundStyle(.primary)
                                    Text(n.borough).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "mappin.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !precincts.isEmpty {
                    Section("Precincts") {
                        ForEach(Array(precincts.enumerated()), id: \.offset) { _, p in
                            Button { go(p.lat, p.lon) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundStyle(.primary)
                                        if !p.borough.isEmpty {
                                            Text(p.borough).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "mappin.circle").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search \(stateName(model.selectedState))")
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
