import SwiftUI

/// General app settings: map appearance, default state, version.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorNeighbors") private var colorNeighbors = true
    @AppStorage("leanTintIntensity") private var leanTintIntensity = 1.0
    @AppStorage("defaultState") private var defaultState = "NY"

    private var intensityLabel: String {
        switch leanTintIntensity {
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
                        Slider(value: $leanTintIntensity, in: 0.25...1.0) {
                            Text("Lean color strength")
                        } minimumValueLabel: {
                            Image(systemName: "circle").imageScale(.small).foregroundStyle(.tertiary)
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        .accessibilityValue(intensityLabel)
                    }
                }

                Section("General") {
                    Picker("Default state", selection: $defaultState) {
                        ForEach(appStates) { Text($0.name).tag($0.abbr) }
                    }
                    LabeledContent("Version", value: appVersion)
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
