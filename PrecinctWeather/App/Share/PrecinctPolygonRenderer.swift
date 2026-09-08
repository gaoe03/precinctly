import CoreLocation
import PrecinctKit
import UIKit

/// Shared vector drawing path used by online and offline share-card maps.
enum PrecinctPolygonRenderer {
    static func fill(_ polygons: [PrecinctPolygon],
                     in context: CGContext,
                     color: UIColor,
                     project: (CLLocationCoordinate2D) -> CGPoint) {
        color.setFill()
        for polygon in polygons {
            guard let path = path(for: polygon, project: project) else { continue }
            context.addPath(path)
            context.drawPath(using: .eoFill)
        }
    }

    static func path(for polygon: PrecinctPolygon,
                     project: (CLLocationCoordinate2D) -> CGPoint) -> CGPath? {
        let path = CGMutablePath()
        var drew = false
        for ring in [polygon.exterior] + polygon.interiors where ring.count > 2 {
            path.move(to: project(ring[0]))
            for coordinate in ring.dropFirst() { path.addLine(to: project(coordinate)) }
            path.closeSubpath()
            drew = true
        }
        return drew ? path : nil
    }
}
