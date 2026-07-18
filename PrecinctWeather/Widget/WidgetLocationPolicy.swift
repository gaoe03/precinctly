import CoreLocation
import Foundation

enum WidgetLocationPolicy {
    static func isUsable(horizontalAccuracy: CLLocationAccuracy, age: TimeInterval) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= 100 && abs(age) <= 60
    }

    static func usableLocation(_ location: CLLocation?, now: Date = Date()) -> CLLocation? {
        guard let location,
              isUsable(
                horizontalAccuracy: location.horizontalAccuracy,
                age: now.timeIntervalSince(location.timestamp)
              ) else { return nil }
        return location
    }
}
