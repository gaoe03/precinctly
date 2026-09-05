import Foundation
import CoreLocation

/// Minimal Well-Known-Binary reader for Polygon (type 3) and MultiPolygon
/// (type 6), plus point-in-polygon. Coordinates are stored as (x = lon, y = lat).
/// This is the on-device equivalent of the shapely PIP used in the build pipeline.
enum WKBGeometry {

    struct BoundaryOffset {
        let east: Double
        let north: Double

        var distance: Double { hypot(east, north) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        var valid = true                       // flips false on any out-of-range read
        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func has(_ n: Int) -> Bool {
            if n < 0 || i > bytes.count || n > bytes.count - i {
                valid = false
                return false
            }
            return true
        }
        mutating func invalidate() { valid = false }
        mutating func u8() -> UInt8 {
            guard has(1) else { return 0 }
            defer { i += 1 }
            return bytes[i]
        }
        mutating func u32(_ le: Bool) -> UInt32 {
            guard has(4) else { return 0 }
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(bytes[i + k]) << (8 * UInt32(le ? k : 3 - k)) }
            i += 4
            return v
        }
        mutating func f64(_ le: Bool) -> Double {
            guard has(8) else { return 0 }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(bytes[i + k]) << (8 * UInt64(le ? k : 7 - k)) }
            i += 8
            return Double(bitPattern: bits)
        }
    }

    /// A polygon as rings; ring 0 is the exterior, the rest are holes. Points are (lon, lat).
    typealias Polygon = [[(lon: Double, lat: Double)]]

    private static func readPolygons(_ r: inout Reader, allowMultiPolygon: Bool = true) -> [Polygon] {
        guard r.i < r.bytes.count else { return [] }
        let byteOrder = r.u8()
        guard byteOrder == 0 || byteOrder == 1 else {
            r.invalidate()
            return []
        }
        let le = byteOrder == 1
        let type = r.u32(le)
        guard r.valid else { return [] }
        switch type {
        case 3:
            let polygon = readPolygon(&r, le)
            return r.valid ? [polygon] : []
        case 6 where allowMultiPolygon:
            let n = r.u32(le)
            guard r.valid, Int(n) <= (r.bytes.count - r.i) / 5 else {
                r.invalidate()
                return []
            }
            var out: [Polygon] = []
            for _ in 0..<n {
                let polys = readPolygons(&r, allowMultiPolygon: false)
                guard r.valid else { return [] }
                out.append(contentsOf: polys)
            }
            return out
        default:
            r.invalidate()
            return []
        }
    }

    private static func readPolygon(_ r: inout Reader, _ le: Bool) -> Polygon {
        let nRings = r.u32(le)
        guard r.valid, Int(nRings) <= (r.bytes.count - r.i) / 4 else {
            r.invalidate()
            return []
        }
        var rings: Polygon = []
        for _ in 0..<nRings {
            let nPts = r.u32(le)
            // WKB linear rings contain at least four points and repeat the first point at the end.
            guard r.valid, nPts >= 4, Int(nPts) <= (r.bytes.count - r.i) / 16 else {
                r.invalidate()
                return []
            }
            var pts: [(lon: Double, lat: Double)] = []
            pts.reserveCapacity(Int(nPts))
            for _ in 0..<nPts {
                let x = r.f64(le), y = r.f64(le)
                guard r.valid, x.isFinite, y.isFinite else {
                    r.invalidate()
                    return []
                }
                pts.append((x, y))
            }
            guard let first = pts.first, let last = pts.last,
                  first.lon == last.lon, first.lat == last.lat else {
                r.invalidate()
                return []
            }
            rings.append(pts)
        }
        return rings
    }

    private enum RingLocation { case outside, inside, boundary }

    private static func ringLocation(_ ring: [(lon: Double, lat: Double)],
                                     _ x: Double, _ y: Double) -> RingLocation {
        guard ring.count >= 4 else { return .outside }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let (xi, yi) = ring[i]
            let (xj, yj) = ring[j]
            let dx = xj - xi
            let dy = yj - yi
            let cross = (x - xi) * dy - (y - yi) * dx
            let scale = max(1, abs(dx), abs(dy))
            let tolerance = 1e-12 * scale * scale
            if abs(cross) <= tolerance,
               x >= min(xi, xj) - tolerance, x <= max(xi, xj) + tolerance,
               y >= min(yi, yj) - tolerance, y <= max(yi, yj) + tolerance {
                return .boundary
            }
            if (yi > y) != (yj > y),
               x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside ? .inside : .outside
    }

    private static func polygons(_ data: Data) -> [Polygon] {
        var reader = Reader(data)
        let result = readPolygons(&reader)
        return reader.valid && reader.i == reader.bytes.count ? result : []
    }

    private static func contains(_ parsed: [Polygon], lon: Double, lat: Double) -> Bool {
        for poly in parsed {
            guard let ext = poly.first, ringLocation(ext, lon, lat) == .inside else { continue }
            if poly.dropFirst().contains(where: { ringLocation($0, lon, lat) != .outside }) { continue }
            return true
        }
        return false
    }

    /// True if (lon, lat) is inside the geometry (inside an exterior ring and not in a hole).
    static func contains(_ data: Data, lon: Double, lat: Double) -> Bool {
        guard lon.isFinite, lat.isFinite else { return false }
        return contains(polygons(data), lon: lon, lat: lat)
    }

    /// Offset from a point to the nearest point on the geometry boundary, measured in meters.
    /// Search uses the direction as well as the distance so multiple nearby precincts must
    /// actually surround a source-data seam instead of merely sharing one outer coverage edge.
    static func nearestBoundaryOffsetMeters(_ data: Data, lon: Double, lat: Double) -> BoundaryOffset? {
        guard lon.isFinite, lat.isFinite, (-90...90).contains(lat) else { return nil }
        let parsed = polygons(data)
        guard !parsed.isEmpty else { return nil }
        if contains(parsed, lon: lon, lat: lat) { return BoundaryOffset(east: 0, north: 0) }

        let metersPerLatitudeDegree = 111_320.0
        let metersPerLongitudeDegree = metersPerLatitudeDegree
            * max(0.01, cos(lat * .pi / 180))
        var bestSquared = Double.infinity
        var bestOffset: BoundaryOffset?

        for polygon in parsed {
            for ring in polygon where ring.count >= 2 {
                for index in 1..<ring.count {
                    let start = ring[index - 1]
                    let end = ring[index]
                    let ax = (start.lon - lon) * metersPerLongitudeDegree
                    let ay = (start.lat - lat) * metersPerLatitudeDegree
                    let bx = (end.lon - lon) * metersPerLongitudeDegree
                    let by = (end.lat - lat) * metersPerLatitudeDegree
                    let dx = bx - ax
                    let dy = by - ay
                    let lengthSquared = dx * dx + dy * dy
                    let t = lengthSquared == 0 ? 0 : min(1, max(0, -(ax * dx + ay * dy) / lengthSquared))
                    let closestX = ax + t * dx
                    let closestY = ay + t * dy
                    let squared = closestX * closestX + closestY * closestY
                    if squared < bestSquared {
                        bestSquared = squared
                        bestOffset = BoundaryOffset(east: closestX, north: closestY)
                    }
                }
            }
        }
        return bestSquared.isFinite ? bestOffset : nil
    }

    /// Shortest distance from a point to the geometry boundary, measured in meters.
    static func distanceMeters(_ data: Data, lon: Double, lat: Double) -> Double? {
        nearestBoundaryOffsetMeters(data, lon: lon, lat: lat)?.distance
    }

    /// True when at least one pair of nearest boundaries lies on opposite sides of the point.
    /// Two boundaries on the same side describe an outer coverage edge, not an internal seam.
    static func boundariesBracketPoint(_ offsets: [BoundaryOffset]) -> Bool {
        for firstIndex in offsets.indices {
            let first = offsets[firstIndex]
            guard first.distance > 0 else { continue }
            for secondIndex in offsets.indices where secondIndex > firstIndex {
                let second = offsets[secondIndex]
                guard second.distance > 0 else { continue }
                if first.east * second.east + first.north * second.north < 0 {
                    return true
                }
            }
        }
        return false
    }

    /// True when nearby precinct geometry occupies nearly every direction around a point.
    /// Internal source seams are narrow, so a 10-meter ring crosses precinct polygons in all
    /// but the directions that run along the seam. At an outer coverage edge, a broad outward
    /// arc remains uncovered even when two precinct corners happen to bracket the point.
    static func geometryLocallySurroundsPoint(_ geometries: [Data], lon: Double, lat: Double,
                                              radiusMeters: Double) -> Bool {
        guard !geometries.isEmpty, lon.isFinite, lat.isFinite, (-90...90).contains(lat),
              radiusMeters.isFinite, radiusMeters > 0 else { return false }

        let sampleCount = 16
        let requiredCoveredSamples = 12
        let metersPerLatitudeDegree = 111_320.0
        let metersPerLongitudeDegree = metersPerLatitudeDegree
            * max(0.01, cos(lat * .pi / 180))
        let parsedGeometries = geometries.map(polygons).filter { !$0.isEmpty }
        guard !parsedGeometries.isEmpty else { return false }
        var coveredSamples = 0

        for sample in 0..<sampleCount {
            let angle = 2 * Double.pi * Double(sample) / Double(sampleCount)
            let sampleLon = lon + radiusMeters * cos(angle) / metersPerLongitudeDegree
            let sampleLat = lat + radiusMeters * sin(angle) / metersPerLatitudeDegree
            if parsedGeometries.contains(where: { contains($0, lon: sampleLon, lat: sampleLat) }) {
                coveredSamples += 1
            }
        }
        return coveredSamples >= requiredCoveredSamples
    }

    /// Exterior rings as coordinate arrays, for drawing on a Map.
    static func exteriorRings(_ data: Data) -> [[CLLocationCoordinate2D]] {
        polygons(data).compactMap { poly in
            poly.first?.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }
}
