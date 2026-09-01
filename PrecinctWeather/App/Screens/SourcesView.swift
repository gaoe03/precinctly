import SwiftUI

struct SourcesView: View {
    var body: some View {
        List {
            Section("How the data is built") {
                Text("Precinctly combines boundaries, election results, and demographic statistics into an offline SQLite database. We join and crosswalk records, simplify map shapes, and calculate the values shown in the app.")
                Text("No source listed here endorses Precinctly. Data is provided as is.")
                    .foregroundStyle(.secondary)
            }

            Section("Government data") {
                source(
                    "U.S. Census Bureau",
                    "2020 TIGER/Line precinct boundaries, 2020 redistricting data, and 2019–2023 American Community Survey estimates.",
                    "https://www.census.gov/programs-surveys/geography/guidance/tiger-data-products-guide.html"
                )
                source(
                    "California Statewide Database",
                    "California 2024 precinct boundaries, crosswalks, and election returns.",
                    "https://statewidedatabase.org/d20/g24.html"
                )
            }

            Section("Election and redistricting data") {
                sourceNote(
                    "Privately supplied DMV dataset",
                    "Curated precinct boundaries, election results, and demographic fields for Washington, DC, Montgomery and Prince George's Counties, and Northern Virginia. DC election values use 2020. Maryland and Virginia use the source's latest available results."
                )
                source(
                    "DC Open Data",
                    "Public 2019 Washington, DC precinct boundaries used as geometry controls when preparing the private DMV shapes.",
                    "https://opendata.dc.gov/"
                )
                source(
                    "Dave's Redistricting",
                    "New York, Massachusetts, and Texas election and voting-age population fields. © 2024–2026 Social Good Fund.",
                    "https://github.com/dra2020/vtd_data/tree/22cb7f7a653140d260aafebf4716a7bb13c1b935"
                )
                source(
                    "ALARM Project",
                    "Population and race inputs, plus California 2016 and 2020 presidential crosswalks, by Christopher T. Kenny and Cory McCartan.",
                    "https://github.com/alarm-redist/census-2020/tree/243c8a8134ecf8151777a9388c48323e274767e2"
                )
                source(
                    "Voting and Election Science Team",
                    "Precinct-level election data used by the ALARM and Dave's Redistricting source files.",
                    "https://election.lab.ufl.edu/precinct-data/"
                )
                source(
                    "Redistricting Data Hub",
                    "This data was generated using data from the Redistricting Data Hub. This map was created using data from the Redistricting Data Hub.",
                    "https://redistrictingdatahub.org/terms-and-conditions/"
                )
                source(
                    "The New York Times",
                    "Massachusetts 2024 presidential results include data from The New York Times.",
                    "https://github.com/nytimes/presidential-precinct-map-2024"
                )
            }

            Section("License information") {
                source(
                    "CC BY-SA 4.0",
                    "Some packaged data is offered under the Creative Commons Attribution-ShareAlike 4.0 license, with additional source terms noted above.",
                    "https://creativecommons.org/licenses/by-sa/4.0/"
                )
                source(
                    "Dave's Redistricting terms",
                    "Terms supplied with the source archives include an additional no-sale condition.",
                    "https://davesredistricting.org/TermsOfUse-July-2024.pdf"
                )
                source(
                    "Statewide Database terms",
                    "Current terms published by the California Statewide Database.",
                    "https://dev.statewidedatabase.org/terms-conditions"
                )
            }
        }
        .navigationTitle("Sources and Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func source(_ title: String, _ detail: String, _ urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 2)
        }
        .accessibilityHint("Opens the source website")
    }

    private func sourceNote(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
