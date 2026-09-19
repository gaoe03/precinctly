import SwiftUI
import PrecinctKit

// MARK: - By the Numbers
//
// A plain list: the area title (tap it to pick a county), a four-stat overview, then a chart for
// every measure (`NumbersCombined`). Standing caveats live behind the info button.

struct FunFactsView: View {
    @EnvironmentObject var model: LocationModel
    @Environment(\.dynamicTypeSize) private var dts
    @State private var overview: ScopeOverview?
    @State private var counties: [String] = []
    @State private var county: String?
    @State private var loading = false
    @State private var showAbout = false
    @State private var showCountyPicker = false
    @State private var detail: NumbersDetailSpec?
    @State private var focusTarget: String?
    // Cache by scope so re-opening a county (or flipping back to "All") is instant.
    @State private var cache: [String: ScopeOverview] = [:]

    private var scopeKey: String { "\(model.selectedState)|\(county ?? "")" }
    private var scopeName: String { county.map { countyDisplay($0) } ?? stateName(model.selectedState) }

    /// Load the current scope's overview. Cached scopes return instantly. The charts below load
    /// their own distributions.
    private func load() async {
        let key = scopeKey, state = model.selectedState, c = county
        if let hit = cache[key] { overview = hit; loading = false; return }
        overview = nil; loading = true
        await Task.yield()                            // let the page (menu + spinner) paint first
        guard scopeKey == key else { return }
        let o: ScopeOverview
        if let region = coverageRegion(state), region.isAggregate {
            o = PrecinctDB.shared.scopeOverview(region: region)
        } else {
            o = PrecinctDB.shared.scopeOverview(state: state, county: c)
        }
        guard scopeKey == key else { return }
        overview = o; loading = false
        cache[key] = o
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section { scopeRow }
                    .listSectionSeparator(.hidden).listRowSeparator(.hidden)

                if loading && overview == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }

                if let overview {
                    Section {
                        OverviewGrid(overview: overview)
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)
                    NumbersCombined(county: county, scopeName: scopeName)
                } else if !loading {
                    Text("No precincts in this area.")
                        .font(.bt(.subheadline)).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section {
                    Text("Presidential results use each precinct's latest available election. Demographics use the 2020 Census and the American Community Survey.")
                        .brandNoteStyle()
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .onChange(of: focusTarget) {
                guard let target = focusTarget else { return }
                // A List only estimates the position of rows it has not laid out yet, so the first
                // jump can land short. A second pass after layout settles lands exactly.
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .top) }
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                }
            }
            #if DEBUG
            .task(id: overview == nil) {
                // Screenshot capture: scroll straight to one chart.
                guard let target = UserDefaults.standard.string(forKey: "numbersScroll"), overview != nil else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                proxy.scrollTo(target, anchor: .top)
                try? await Task.sleep(nanoseconds: 600_000_000)
                proxy.scrollTo(target, anchor: .top)
            }
            #endif
            }
            .brandList()
            .brandSolidBar()
            .environment(\.openNumbersDetail) { detail = $0 }
            .navigationDestination(item: $detail) { spec in
                NumbersDetail(spec: spec, county: county, scopeName: scopeName)
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAbout) { AboutDataSheet() }
            .sheet(isPresented: $showCountyPicker) {
                CountyPicker(
                    state: model.selectedState,
                    counties: counties,
                    selection: $county
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: {
                        Image(systemName: "info")
                            .font(.bt(.body, .semibold)).foregroundStyle(.secondary)
                            .brandToolbarChip()
                    }
                    .accessibilityLabel("About this data")
                }
                .brandHideGlass()
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showFunFacts = false } label: {
                        Image(systemName: "xmark").font(.bt(.body, .semibold)).foregroundStyle(.secondary)
                            .brandToolbarChip()
                    }
                    .accessibilityLabel("Close")
                }
                .brandHideGlass()
            }
            // The tour's step, inside the sheet that covers it.
            .safeAreaInset(edge: .bottom) {
                TourSheetGuide(step: .numbers,
                               text: "Each chart shows how every precinct in \(scopeName) compares. Yours is marked You.",
                               continueTitle: "Continue", close: { model.showFunFacts = false })
            }
        }
        .environment(\.brandClose, { model.showFunFacts = false })
        .task(id: model.selectedState) {
            county = nil
            counties = coverageRegion(model.selectedState)?.isAggregate == true
                ? [] : PrecinctDB.shared.counties(state: model.selectedState)
        }
        .task(id: scopeKey) {
            await load()
            try? await Task.sleep(nanoseconds: 300_000_000)
            // A tapped stat on the card opens this page scrolled to its chart.
            if let m = model.numbersFocus {
                model.numbersFocus = nil
                focusTarget = m.rawValue
            }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-openAbout") { showAbout = true }
            if args.contains("-openCounties") { showCountyPicker = true }
            if let m = UserDefaults.standard.string(forKey: "openDetail").flatMap(Metric.init(rawValue:)) {
                detail = NumbersDetailSpec(metric: m, bucket: UserDefaults.standard.string(forKey: "exploreBucket").flatMap { Int($0) }, opensOnYou: true)
            }
            #endif
        }
    }

    /// The area is the page title. Tapping it opens the county picker.
    @ViewBuilder
    private var scopeRow: some View {
        let isAggregate = coverageRegion(model.selectedState)?.isAggregate == true
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("By the Numbers").font(.bt(.subheadline, .semibold)).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scopeName)
                    .brandScaledDisplay(32, .heavy).foregroundStyle(Color(uiColor: .label))
                    .lineLimit(dts.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.7)
                if !isAggregate {
                    Image(systemName: "chevron.down").font(.bt(.title3, .bold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        Group {
            if isAggregate {
                title
            } else {
                Button { showCountyPicker = true } label: { title }.buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isAggregate ? [] : .isButton)
        .accessibilityHint(isAggregate ? "" : "Choose a county")
    }
}

private struct CountyPicker: View {
    @Environment(\.dismiss) private var dismiss
    let state: String
    let counties: [String]
    @Binding var selection: String?
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return counties }
        return counties.filter { countyDisplay($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { choose(nil) } label: {
                    choiceLabel("All of \(stateName(state))", selected: selection == nil)
                }
                .brandRowRule(last: filtered.isEmpty)
                ForEach(Array(filtered.enumerated()), id: \.element) { i, county in
                    Button { choose(county) } label: {
                        choiceLabel(countyDisplay(county), selected: selection == county)
                    }
                    .brandRowRule(last: i == filtered.count - 1)
                }
            }
            .brandList()
            .searchable(text: $query, prompt: "Search counties")
            .navigationTitle("Choose a county")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { BrandDoneButton { dismiss() } }.brandHideGlass()
            }
        }
    }

    private func choose(_ county: String?) {
        selection = county
        dismiss()
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            // Color.primary, not the hierarchical .primary: inside a List Button the
            // hierarchy resolves against the tint and every row renders link-blue.
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color(uiColor: .label)) }
        }
    }
}

// MARK: - Overview and About this data

private struct OverviewGrid: View {
    @Environment(\.dynamicTypeSize) private var dts
    let overview: ScopeOverview
    private var leanText: String {
        guard let s = overview.avgDemShare else { return "No data" }
        let m = Int(((s - 0.5) * 200).rounded())
        if m > 0 { return "D+\(m)" }
        if m < 0 { return "R+\(-m)" }
        return "Even"
    }
    var body: some View {
        let cols = Array(repeating: GridItem(.flexible()), count: dts.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: cols, spacing: 16) {
            BigStat(value: overview.precinctCount.formatted(), label: "Precincts", delta: nil)
            BigStat(value: overview.totalPopulation.map { Fmt.compact($0) } ?? "No data", label: "Population", delta: nil)
            BigStat(value: leanText, label: "Presidential lean", delta: nil, valueColor: Palette.lean(overview.avgDemShare))
            BigStat(value: overview.medianIncome.map { Fmt.incomeTopCoded($0) } ?? "No data", label: "Median precinct income", delta: nil)
        }
        .padding(.vertical, 4)
    }
}

private struct AboutDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    aboutRow("Politics", "Each precinct's latest available presidential election. The year can differ by precinct.")
                    aboutRow("Demographics", "The 2020 Census and the Census Bureau's American Community Survey, a rolling five-year estimate.")
                    NavigationLink { SourcesView() } label: { BrandLinkRow(title: "Sources and licenses") }
                        .brandHideDisclosure()
                } header: { BrandListHeader("Where this comes from") }
                .listRowSeparator(.hidden)
                Section {
                    aboutRow("Income tops out", "The Census reports household income only up to $250,000, shown here as $250k+, so many well-off precincts tie at that ceiling.")
                    aboutRow("Race can pass 100%", "Race and Hispanic origin are counted separately, so a precinct's race shares can add up to more than 100%.")
                    aboutRow("Small precincts sit out", "Rankings skip very small precincts (under about 500 people or 100 votes), where a single household can swing the number.")
                    aboutRow("Turnout can pass 100%", "Turnout compares votes with a Census estimate of eligible adults. Where that estimate runs low, the result can pass 100%. Up to 105% shows as 100%. Above that, the app leaves turnout out and shows the vote count.")
                } header: { BrandListHeader("Things worth knowing") }
                .listRowSeparator(.hidden)
            }
            .brandList()
            .navigationTitle("About this data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { BrandDoneButton { dismiss() } }.brandHideGlass() }
        }
        .environment(\.brandClose, { dismiss() })
    }
    private func aboutRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.bt(.subheadline, .semibold))
            Text(detail).brandNoteStyle()
        }
        .padding(.vertical, 2)
    }
}
