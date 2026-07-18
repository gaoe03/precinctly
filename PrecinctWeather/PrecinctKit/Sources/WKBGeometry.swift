import Foundation
import CoreLocation

/// Minimal Well-Known-Binary reader for Polygon (type 3) and MultiPolygon
/// (type 6), plus point-in-polygon. Coordinates are stored as (x = lon, y = lat).
/// This is the on-device equivalent of the shapely PIP used in the build pipeline.
enum WKBGeometry {

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

    /// True if (lon, lat) is inside the geometry (inside an exterior ring and not in a hole).
    static func contains(_ data: Data, lon: Double, lat: Double) -> Bool {
        guard lon.isFinite, lat.isFinite else { return false }
        for poly in polygons(data) {
            guard let ext = poly.first, ringLocation(ext, lon, lat) == .inside else { continue }
            if poly.dropFirst().contains(where: { ringLocation($0, lon, lat) != .outside }) { continue }
            return true
        }
        return false
    }

    /// Exterior rings as coordinate arrays, for drawing on a Map.
    static func exteriorRings(_ data: Data) -> [[CLLocationCoordinate2D]] {
        polygons(data).compactMap { poly in
            poly.first?.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }
}
