import CoreLocation
import MapKit

/// One drawable polygon with its interior rings kept attached to its exterior ring.
public struct PrecinctPolygon: Sendable {
    public let exterior: [CLLocationCoordinate2D]
    public let interiors: [[CLLocationCoordinate2D]]

    public init(exterior: [CLLocationCoordinate2D],
                interiors: [[CLLocationCoordinate2D]] = []) {
        self.exterior = exterior
        self.interiors = interiors
    }

    /// MapKit polygon that preserves interior holes for SwiftUI's `MapPolygon` overlay.
    public var mapPolygon: MKPolygon {
        let holes = interiors.map { MKPolygon(coordinates: $0, count: $0.count) }
        return MKPolygon(coordinates: exterior, count: exterior.count,
                         interiorPolygons: holes)
    }
}
