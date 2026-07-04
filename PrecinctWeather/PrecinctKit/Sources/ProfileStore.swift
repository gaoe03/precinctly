import Foundation

/// Shared App Group identifier. Must match the App Groups capability on both the
/// app and the widget extension entitlements.
public enum AppGroup {
    public static let id = "group.com.gaoe.PrecinctWeather"
}

/// Tiny cache the app writes (latest precinct profile) and the widget reads.
/// Backed by a JSON file in the App Group container (atomic write, cross-process safe).
///
/// PRIVACY INVARIANT: the persisted `PrecinctProfile` must NEVER contain raw
/// coordinates. Only precinct-level results are written; the device location
/// stays in memory and never leaves the device.
public enum ProfileStore {
    private static let filename = "current_profile.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent(filename)
    }

    public static func save(_ profile: PrecinctProfile) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func load() -> PrecinctProfile? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PrecinctProfile.self, from: data)
    }
}
