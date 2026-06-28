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
            if i + n > bytes.count { valid = false; return false }
            return true
        }
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

    private static func readPolygons(_ r: inout Reader) -> [Polygon] {
        guard r.i < r.bytes.count else { return [] }
        let le = (r.u8() == 1)
        let type = r.u32(le)
        guard r.valid else { return [] }
        switch type {
        case 3:
            return [readPolygon(&r, le)]
        case 6:
            let n = r.u32(le)
            guard r.valid, n <= UInt32(r.bytes.count) else { return [] }   // sanity cap
            var out: [Polygon] = []
            for _ in 0..<n {
                let polys = readPolygons(&r)
                if !r.valid { break }
                out.append(contentsOf: polys)
            }
            return out
        default:
            return []
        }
    }

    private static func readPolygon(_ r: inout Reader, _ le: Bool) -> Polygon {
        let nRings = r.u32(le)
        guard r.valid, nRings <= UInt32(r.bytes.count) else { return [] }
        var rings: Polygon = []
        for _ in 0..<nRings {
            let nPts = r.u32(le)
            // each point is 16 bytes; a count beyond what's left means corruption
            guard r.valid, Int(nPts) <= r.bytes.count / 16 else { return rings }
            var pts: [(lon: Double, lat: Double)] = []
            pts.reserveCapacity(Int(nPts))
            for _ in 0..<nPts {
                let x = r.f64(le), y = r.f64(le)
                if !r.valid { return rings }
                pts.append((x, y))
            }
            rings.append(pts)
        }
        return rings
    }

    private static func ringContains(_ ring: [(lon: Double, lat: Double)],
                                     _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let (xi, yi) = ring[i]
            let (xj, yj) = ring[j]
            if (yi > y) != (yj > y),
               x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// True if (lon, lat) is inside the geometry (inside an exterior ring and not in a hole).
    static func contains(_ data: Data, lon: Double, lat: Double) -> Bool {
        var r = Reader(data)
        for poly in readPolygons(&r) {
            guard let ext = poly.first, ringContains(ext, lon, lat) else { continue }
            if poly.dropFirst().contains(where: { ringContains($0, lon, lat) }) { continue }
            return true
        }
        return false
    }

    /// Exterior rings as coordinate arrays, for drawing on a Map.
    static func exteriorRings(_ data: Data) -> [[CLLocationCoordinate2D]] {
        var r = Reader(data)
        return readPolygons(&r).compactMap { poly in
            poly.first?.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }
}
