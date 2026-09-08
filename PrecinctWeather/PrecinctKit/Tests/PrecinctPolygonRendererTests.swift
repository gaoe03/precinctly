import CoreLocation
import XCTest
import UIKit
@testable import PrecinctKit

final class PrecinctPolygonRendererTests: XCTestCase {
    func testProductionShareFillLeavesHoleUnfilledAndFillsShellAndIsland() throws {
        let polygon = PrecinctPolygon(
            exterior: ring(0, 0, 80, 80),
            interiors: [ring(30, 30, 50, 50)]
        )
        let island = PrecinctPolygon(exterior: ring(85, 10, 95, 20))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let project: (CLLocationCoordinate2D) -> CGPoint = {
            CGPoint(x: $0.longitude, y: $0.latitude)
        }
        let image = render([polygon, island], size: CGSize(width: 100, height: 100),
                           project: project, legacy: false)
        let before = render([polygon, island], size: CGSize(width: 100, height: 100),
                            project: project, legacy: true)
        attach(before, name: "Synthetic hole before")
        attach(image, name: "Synthetic hole after")
        try? before.pngData()?.write(to: URL(fileURLWithPath: "/tmp/precinct-hole-before.png"))
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/precinct-hole-after.png"))

        assertColor(try color(before, at: CGPoint(x: 40, y: 40)), equals: .red)
        assertColor(try color(image, at: CGPoint(x: 10, y: 10)), equals: .red)
        assertColor(try color(image, at: CGPoint(x: 40, y: 40)), equals: .white)
        assertColor(try color(image, at: CGPoint(x: 90, y: 15)), equals: .red)
    }

    func testBundledGreeneGeometryLeavesKnownHoleUnfilled() throws {
        let db = PrecinctDB.shared
        let hit = try XCTUnwrap(db.precinct(unitID: "36039-:-36039000039"))
        XCTAssertEqual(hit.polygons.count, 1)
        XCTAssertEqual(hit.polygons[0].interiors.count, 1)
        XCTAssertNil(db.lookup(lon: -74.134698, lat: 42.188291))

        let size = CGSize(width: 512, height: 300)
        let bounds = bounds(of: hit.polygons)
        let project: (CLLocationCoordinate2D) -> CGPoint = { coordinate in
            CGPoint(
                x: (coordinate.longitude - bounds.minLon) / (bounds.maxLon - bounds.minLon) * size.width,
                y: (bounds.maxLat - coordinate.latitude) / (bounds.maxLat - bounds.minLat) * size.height
            )
        }
        let image = render(hit.polygons, size: size, project: project, legacy: false)
        let before = render(hit.polygons, size: size, project: project, legacy: true)
        attach(before, name: "Greene County hole before")
        attach(image, name: "Greene County hole after")
        try? before.pngData()?.write(to: URL(fileURLWithPath: "/tmp/greene-hole-before.png"))
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/greene-hole-after.png"))

        let shellCoordinate = CLLocationCoordinate2D(latitude: 42.150568,
                                                      longitude: -74.15579761658954)
        let holeCoordinate = CLLocationCoordinate2D(latitude: 42.1941485,
                                                     longitude: -74.1373808080522)
        assertColor(try color(before, at: project(holeCoordinate)), equals: .red)
        assertColor(try color(image, at: project(shellCoordinate)), equals: .red)
        assertColor(try color(image, at: project(holeCoordinate)), equals: .white)
    }

    private func ring(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double)
        -> [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: minY, longitude: minX),
            CLLocationCoordinate2D(latitude: minY, longitude: maxX),
            CLLocationCoordinate2D(latitude: maxY, longitude: maxX),
            CLLocationCoordinate2D(latitude: maxY, longitude: minX),
            CLLocationCoordinate2D(latitude: minY, longitude: minX),
        ]
    }

    private func render(_ polygons: [PrecinctPolygon], size: CGSize,
                        project: @escaping (CLLocationCoordinate2D) -> CGPoint,
                        legacy: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.cgContext.fill(CGRect(origin: .zero, size: size))
            if legacy {
                UIColor.red.setFill()
                let path = CGMutablePath()
                for polygon in polygons {
                    let ring = polygon.exterior
                    guard ring.count > 2 else { continue }
                    path.move(to: project(ring[0]))
                    for coordinate in ring.dropFirst() { path.addLine(to: project(coordinate)) }
                    path.closeSubpath()
                }
                renderer.cgContext.addPath(path)
                renderer.cgContext.fillPath()
            } else {
                PrecinctPolygonRenderer.fill(polygons, in: renderer.cgContext, color: .red,
                                              project: project)
            }
        }
    }

    private func color(_ image: UIImage, at point: CGPoint) throws -> UIColor {
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = Int(point.y) * cgImage.bytesPerRow + Int(point.x) * 4
        return UIColor(red: CGFloat(bytes[offset]) / 255,
                       green: CGFloat(bytes[offset + 1]) / 255,
                       blue: CGFloat(bytes[offset + 2]) / 255,
                       alpha: CGFloat(bytes[offset + 3]) / 255)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func bounds(of polygons: [PrecinctPolygon])
        -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        let coordinates = polygons.flatMap(\.exterior)
        return (
            coordinates.map(\.longitude).min()!, coordinates.map(\.latitude).min()!,
            coordinates.map(\.longitude).max()!, coordinates.map(\.latitude).max()!
        )
    }

    private func assertColor(_ actual: UIColor, equals expected: UIColor,
                             file: StaticString = #filePath, line: UInt = #line) {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        XCTAssertTrue(actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa), file: file, line: line)
        XCTAssertTrue(expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea), file: file, line: line)
        XCTAssertEqual(ar, er, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ag, eg, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ab, eb, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(aa, ea, accuracy: 0.01, file: file, line: line)
    }
}
