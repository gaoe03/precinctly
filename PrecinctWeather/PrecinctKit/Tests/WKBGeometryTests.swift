import CoreLocation
import Foundation
import XCTest
@testable import PrecinctKit

final class WKBGeometryTests: XCTestCase {
    private let square = [
        Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10), Point(0, 0),
    ]

    func testPolygonContainmentAndExteriorExtractionInBothByteOrders() {
        for littleEndian in [true, false] {
            let data = polygon([square], littleEndian: littleEndian)

            XCTAssertTrue(WKBGeometry.contains(data, lon: 5, lat: 5))
            XCTAssertFalse(WKBGeometry.contains(data, lon: -1, lat: 5))
            XCTAssertEqual(WKBGeometry.exteriorRings(data).count, 1)
            XCTAssertEqual(WKBGeometry.exteriorRings(data).first?.count, square.count)
        }
    }

    func testPolygonHoleAndMultipolygon() {
        let hole = [
            Point(4, 4), Point(6, 4), Point(6, 6), Point(4, 6), Point(4, 4),
        ]
        let withHole = polygon([square, hole])

        XCTAssertTrue(WKBGeometry.contains(withHole, lon: 2, lat: 2))
        XCTAssertFalse(WKBGeometry.contains(withHole, lon: 5, lat: 5))

        let second = square.map { Point($0.x + 20, $0.y) }
        let data = multiPolygon([polygon([square]), polygon([second])])
        XCTAssertTrue(WKBGeometry.contains(data, lon: 5, lat: 5))
        XCTAssertTrue(WKBGeometry.contains(data, lon: 25, lat: 5))
        XCTAssertFalse(WKBGeometry.contains(data, lon: 15, lat: 5))
        XCTAssertEqual(WKBGeometry.exteriorRings(data).count, 2)
    }

    func testExactBoundaryIsNotInterior() {
        let data = polygon([square])
        let boundaryPoints = [
            Point(0, 0), Point(5, 0), Point(10, 5), Point(5, 10), Point(0, 5),
        ]

        for point in boundaryPoints {
            XCTAssertFalse(
                WKBGeometry.contains(data, lon: point.x, lat: point.y),
                "Boundary point \(point) must not be treated as interior"
            )
        }
    }

    func testEveryTruncatedPrefixFailsClosed() {
        let hole = [
            Point(4, 4), Point(6, 4), Point(6, 6), Point(4, 6), Point(4, 4),
        ]
        let valid = polygon([square, hole])

        for end in 0..<valid.count {
            let truncated = Data(valid.prefix(end))
            XCTAssertFalse(WKBGeometry.contains(truncated, lon: 2, lat: 2), "Accepted prefix length \(end)")
            XCTAssertTrue(WKBGeometry.exteriorRings(truncated).isEmpty, "Drew prefix length \(end)")
        }
    }

    func testMalformedGeometryNeverProducesDrawableRings() {
        let unclosed = Array(square.dropLast())
        var nonFinite = square
        nonFinite[1] = Point(.nan, 0)
        var infinite = square
        infinite[1] = Point(.infinity, 0)

        var invalidByteOrder = polygon([square], littleEndian: false)
        invalidByteOrder[0] = 2

        var unsupportedType = Data([1])
        append(UInt32(99), littleEndian: true, to: &unsupportedType)

        var hugeRingCount = Data([1])
        append(UInt32(3), littleEndian: true, to: &hugeRingCount)
        append(UInt32.max, littleEndian: true, to: &hugeRingCount)

        var hugePointCount = Data([1])
        append(UInt32(3), littleEndian: true, to: &hugePointCount)
        append(UInt32(1), littleEndian: true, to: &hugePointCount)
        append(UInt32.max, littleEndian: true, to: &hugePointCount)

        var hugePolygonCount = Data([1])
        append(UInt32(6), littleEndian: true, to: &hugePolygonCount)
        append(UInt32.max, littleEndian: true, to: &hugePolygonCount)

        let shortRings = (0...3).map { polygon([Array(square.prefix($0))]) }
        let unsupportedChild = multiPolygon([unsupportedType])
        let nestedMultiPolygon = multiPolygon([multiPolygon([polygon([square])])])

        let malformed = [
            Data(), invalidByteOrder, unsupportedType, unsupportedChild, nestedMultiPolygon,
            hugeRingCount, hugePointCount, hugePolygonCount, polygon([unclosed]),
            polygon([nonFinite]), polygon([infinite]), polygon([square]) + Data([0xff]),
        ] + shortRings

        for data in malformed {
            XCTAssertFalse(WKBGeometry.contains(data, lon: 5, lat: 5))
            XCTAssertTrue(WKBGeometry.exteriorRings(data).isEmpty)
        }
    }

    func testNonFiniteQueryCoordinatesAreRejected() {
        let data = polygon([square])
        for point in [Point(.nan, 5), Point(.infinity, 5), Point(5, -.infinity)] {
            XCTAssertFalse(WKBGeometry.contains(data, lon: point.x, lat: point.y))
        }
    }
}

private struct Point: CustomStringConvertible {
    let x: Double
    let y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    var description: String { "(\(x), \(y))" }
}

private func polygon(_ rings: [[Point]], littleEndian: Bool = true) -> Data {
    var data = Data([littleEndian ? 1 : 0])
    append(UInt32(3), littleEndian: littleEndian, to: &data)
    append(UInt32(rings.count), littleEndian: littleEndian, to: &data)
    for ring in rings {
        append(UInt32(ring.count), littleEndian: littleEndian, to: &data)
        for point in ring {
            append(point.x, littleEndian: littleEndian, to: &data)
            append(point.y, littleEndian: littleEndian, to: &data)
        }
    }
    return data
}

private func multiPolygon(_ polygons: [Data], littleEndian: Bool = true) -> Data {
    var data = Data([littleEndian ? 1 : 0])
    append(UInt32(6), littleEndian: littleEndian, to: &data)
    append(UInt32(polygons.count), littleEndian: littleEndian, to: &data)
    polygons.forEach { data.append($0) }
    return data
}

private func append(_ value: UInt32, littleEndian: Bool, to data: inout Data) {
    let ordered = littleEndian ? value.littleEndian : value.bigEndian
    withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
}

private func append(_ value: Double, littleEndian: Bool, to data: inout Data) {
    let ordered = littleEndian ? value.bitPattern.littleEndian : value.bitPattern.bigEndian
    withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
}
