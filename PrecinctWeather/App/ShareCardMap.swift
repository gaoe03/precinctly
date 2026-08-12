import UIKit
import MapKit
import CoreLocation
import PrecinctKit

// MARK: - The share card's map hero
//
// A real Apple Maps snapshot of the area around the precinct with the precinct drawn on top,
// so someone receiving the card can see WHERE this is, not just an abstract outline. The
// surrounding precincts are tinted by lean exactly as the app tints them, so the card reads as
// a clipping of the app rather than a separate artefact.
//
// `MKMapSnapshotter` is async and needs the network for tiles. When it fails (offline, or a
// region MapKit won't serve) the same polygons are drawn onto plain paper instead, so the card
// always has a hero and never a blank rectangle.

enum ShareCardMap {

    static func image(profile: PrecinctProfile,
                      rings: [[CLLocationCoordinate2D]],
                      size: CGSize,
                      scale: CGFloat) async -> UIImage? {
        guard let box = boundingBox(of: rings) else { return nil }
        let region = paddedRegion(for: box, aspect: size.width / size.height)
        let neighbors = await neighborShapes(profile: profile, center: box.center)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        // Points of interest stay on: a Whole Foods or a park is exactly what makes a recipient
        // recognise the block. Traffic and buildings off, they only add noise at this size.
        options.showsBuildings = false

        let snapshot = try? await MKMapSnapshotter(options: options).start()

        return UIGraphicsImageRenderer(size: size, format: format(scale: scale)).image { ctx in
            let cg = ctx.cgContext
            if let snapshot {
                snapshot.image.draw(at: .zero)
            } else {
                UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1).setFill()
                cg.fill(CGRect(origin: .zero, size: size))
            }
            // One projection for both paths so the fallback lines up with the snapshot version.
            let project: (CLLocationCoordinate2D) -> CGPoint = snapshot.map { snap in
                { snap.point(for: $0) }
            } ?? fallbackProjection(region: region, size: size)

            // Surrounding precincts first, and much lighter than the app's on-screen tint. On a
            // live map the tint is the subject; here it is context under a highlighted precinct,
            // and at the app's weight it turned every street name and park to mush.
            for shape in neighbors where shape.id != profile.unitID {
                guard let path = path(for: shape.rings, project: project) else { continue }
                UIColor(Palette.lean(shape.demShare)).withAlphaComponent(0.22).setFill()
                cg.addPath(path); cg.fillPath()
            }

            // The precinct itself: stronger fill, and an outline heavy enough to find at a glance.
            guard let mine = path(for: rings, project: project) else { return }
            let lean = UIColor(Palette.lean(profile.leanDemShare))
            lean.withAlphaComponent(0.55).setFill()
            cg.addPath(mine); cg.fillPath()
            cg.setLineJoin(.round)
            UIColor.white.withAlphaComponent(0.9).setStroke()
            cg.addPath(mine); cg.setLineWidth(4.5); cg.strokePath()
            lean.setStroke()
            cg.addPath(mine); cg.setLineWidth(2.5); cg.strokePath()
        }
    }

    private static func format(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat.preferred()
        f.scale = scale
        f.opaque = true
        return f
    }

    /// Nearest precincts in the same county, for context around the subject. Capped well below
    /// the app's on-map limit: this is one small still image, not a pannable map, and every
    /// extra polygon is decode time the share button is waiting on.
    @MainActor
    private static func neighborShapes(profile: PrecinctProfile,
                                       center: CLLocationCoordinate2D) -> [PrecinctPin] {
        let rows = PrecinctDB.shared.countyRows(state: profile.state, county: profile.borough,
                                                lon: center.longitude, lat: center.latitude,
                                                limit: 150)
        return PrecinctDB.makePins(rows)
    }

    private static func path(for rings: [[CLLocationCoordinate2D]],
                             project: (CLLocationCoordinate2D) -> CGPoint) -> CGPath? {
        let path = CGMutablePath()
        var drew = false
        for ring in rings where ring.count > 2 {
            path.move(to: project(ring[0]))
            for c in ring.dropFirst() { path.addLine(to: project(c)) }
            path.closeSubpath()
            drew = true
        }
        return drew ? path : nil
    }

    // MARK: Region math

    private static func boundingBox(of rings: [[CLLocationCoordinate2D]])
        -> (center: CLLocationCoordinate2D, spanLat: Double, spanLon: Double)? {
        var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        var any = false
        for ring in rings { for c in ring {
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            any = true
        }}
        guard any else { return nil }
        return (CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                maxLat - minLat, maxLon - minLon)
    }

    /// Zoom out far enough that the precinct sits inside its neighbourhood instead of filling the
    /// frame, then fit the card's aspect ratio. Precincts are often long slivers, so the padding
    /// is applied to the larger dimension and the smaller one is grown to match the aspect,
    /// otherwise a thin precinct would zoom to a street-level strip with no context at all.
    private static func paddedRegion(for box: (center: CLLocationCoordinate2D, spanLat: Double, spanLon: Double),
                                     aspect: CGFloat) -> MKCoordinateRegion {
        let latMeters = box.spanLat * 111_000
        let lonMeters = box.spanLon * 111_000 * cos(box.center.latitude * .pi / 180)
        let longest = max(latMeters, lonMeters, 250)
        var width = longest * 2.4                      // the context margin
        var height = width / Double(max(aspect, 0.1))
        if height < latMeters * 1.6 {                  // never crop the precinct itself
            height = latMeters * 1.6
            width = height * Double(aspect)
        }
        return MKCoordinateRegion(center: box.center, latitudinalMeters: height, longitudinalMeters: width)
    }

    /// Equirectangular fallback used only when MapKit returns no snapshot, matched to the same
    /// region so the polygons land where they would have on the real map.
    private static func fallbackProjection(region: MKCoordinateRegion,
                                           size: CGSize) -> (CLLocationCoordinate2D) -> CGPoint {
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        return { c in
            CGPoint(x: (c.longitude - minLon) / region.span.longitudeDelta * size.width,
                    y: (maxLat - c.latitude) / region.span.latitudeDelta * size.height)
        }
    }
}
