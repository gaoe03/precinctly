import SwiftUI
import PrecinctKit

/// General app settings: map appearance, default state, version.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorNeighbors") private var colorNeighbors = true
    @AppStorage("leanTintIntensity") private var leanTintIntensity = 0.75   // "Medium"; Bold drowned the basemap
    @AppStorage("defaultState") private var defaultState = "NY"
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    /// Slider value while the finger is down; committed to AppStorage on release. Writing
    /// live restyled every county polygon on every tick, which made the slider itself lag.
    @State private var liveTint: Double? = nil

    private var intensityLabel: String {
        switch liveTint ?? leanTintIntensity {
        case ..<0.4: return "Subtle"
        case ..<0.65: return "Soft"
        case ..<0.9: return "Medium"
        default: return "Bold"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Toggle("Color nearby precincts", isOn: $colorNeighbors)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Lean color strength")
                            Spacer()
                            Text(intensityLabel).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { liveTint ?? leanTintIntensity },
                                              set: { liveTint = $0 }),
                               in: 0.25...1.0) {
                            Text("Lean color strength")
                        } minimumValueLabel: {
                            Image(systemName: "circle").imageScale(.small).foregroundStyle(.tertiary)
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(.tertiary)
                        } onEditingChanged: { editing in
                            if !editing, let v = liveTint { leanTintIntensity = v; liveTint = nil }
                        }
                        .accessibilityValue(intensityLabel)
                    }
                }

                Section {
                    Picker("Default state", selection: $defaultState) {
                        ForEach(appStates) { Text($0.name).tag($0.abbr) }
                    }
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                } header: {
                    Text("General")
                } footer: {
                    Text(Coverage.namesSentence)
                }

                Section("Widget") {
                    Text("Add the Precinct widget from your Home Screen: touch and hold an empty spot, tap Edit, then Add Widget, and search for Precinct.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Link(destination: URL(string: "https://precinct.ethangao.xyz/privacy.html")!) {
                        LabeledContent("Privacy policy") { Image(systemName: "arrow.up.right").font(.footnote) }
                    }
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Boundaries and returns are public data from the Census Bureau and state election offices, joined to the 2020 Census and American Community Survey. Your location is used only on your device and never leaves it.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
