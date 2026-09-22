import UIKit
import SwiftUI
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
// region MapKit won't serve) the same polygons are drawn on the card's plain background instead,
// so the card always has a hero and never a blank rectangle.

enum ShareCardMap {

    static func image(profile: PrecinctProfile,
                      polygons: [PrecinctPolygon],
                      size: CGSize,
                      scale: CGFloat,
                      colorScheme: ColorScheme) async -> UIImage? {
        guard let box = boundingBox(of: polygons.map(\.exterior)) else { return nil }
        let region = paddedRegion(for: box, aspect: size.width / size.height)
        let neighbors = await neighborShapes(profile: profile, center: box.center)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: colorScheme == .dark ? .dark : .light
        )
        // Points of interest stay on: a Whole Foods or a park is exactly what makes a recipient
        // recognise the block. Traffic and buildings off, they only add noise at this size.
        options.showsBuildings = false

        let snapshot = try? await MKMapSnapshotter(options: options).start()
        guard !Task.isCancelled else { return nil }

        return UIGraphicsImageRenderer(size: size, format: format(scale: scale)).image { ctx in
            let cg = ctx.cgContext
            if let snapshot {
                snapshot.image.draw(at: .zero)
            } else {
                fallbackColor(for: colorScheme).setFill()
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
                PrecinctPolygonRenderer.fill(
                    shape.polygons, in: cg,
                    color: UIColor(Palette.lean(shape.demShare)).withAlphaComponent(0.22),
                    project: project
                )
            }

            // The precinct itself: stronger fill, and an outline heavy enough to find at a glance.
            guard !polygons.isEmpty else { return }
            let lean = UIColor(Palette.lean(profile.leanDemShare))
            PrecinctPolygonRenderer.fill(polygons, in: cg,
                                          color: lean.withAlphaComponent(0.55), project: project)
            cg.setLineJoin(.round)
            UIColor.white.withAlphaComponent(0.9).setStroke()
            stroke(polygons, in: cg, width: 4.5, project: project)
            lean.setStroke()
            stroke(polygons, in: cg, width: 2.5, project: project)
        }
    }

    private static func format(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat.preferred()
        f.scale = scale
        f.opaque = true
        return f
    }

    private static func fallbackColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark
            ? UIColor(red: 0.105, green: 0.112, blue: 0.133, alpha: 1)
            : UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)
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

    private static func stroke(_ polygons: [PrecinctPolygon], in context: CGContext,
                               width: CGFloat,
                               project: (CLLocationCoordinate2D) -> CGPoint) {
        for polygon in polygons {
            guard let path = PrecinctPolygonRenderer.path(for: polygon, project: project) else { continue }
            context.addPath(path)
            context.setLineWidth(width)
            context.strokePath()
        }
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
