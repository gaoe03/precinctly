import SwiftUI
import PrecinctKit

/// General app settings: appearance, map look, default state, version.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("colorNeighbors") private var colorNeighbors = true
    @AppStorage("leanTintIntensity") private var leanTintIntensity = 0.5   // soft; full strength drowns the basemap
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
                Section("Appearance") {
                    AppearanceModeRow(selection: $appearanceMode)
                }

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
                    Text("Add the Precinctly widget from your Home Screen: touch and hold an empty spot, tap Edit, then Add Widget, and search for Precinctly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink("Sources and licenses") { SourcesView() }
                    Link(destination: URL(string: "https://precinct.ethangao.xyz/privacy.html")!) {
                        LabeledContent("Privacy policy") { Image(systemName: "arrow.up.right").font(.footnote) }
                    }
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Boundaries, election returns, and demographics are combined from government and third-party sources; full notices are under Sources and licenses. Your location is used only on your device and never leaves it.")
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

/// Three side-by-side tap targets (Light / Dark / Auto), not a menu: the choice is visible
/// at a glance and one tap away. "auto" follows the system setting.
private struct AppearanceModeRow: View {
    @Binding var selection: String

    private let options: [(id: String, label: String, icon: String)] = [
        ("light", "Light", "sun.max.fill"),
        ("dark", "Dark", "moon.fill"),
        ("auto", "Auto", "circle.lefthalf.filled"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.id) { option in
                let selected = selection == option.id
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.id }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.system(size: 19, weight: .medium))
                        Text(option.label)
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) appearance")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(.vertical, 4)
    }
}
