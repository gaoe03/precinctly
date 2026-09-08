import SwiftUI
import UIKit
import XCTest
@testable import PrecinctKit

final class ShareCardRendererTests: XCTestCase {
    @MainActor
    func testExportFollowsAppearanceAndHasNoTransparentOrBlankEdges() throws {
        let profile = try XCTUnwrap(PrecinctDB.shared.precinct(unitID: "41001-:-0001")?.profile)
        let trend = PrecinctDB.shared.electionSeries(unitID: profile.unitID)
            .filter { $0.office == "president" && $0.demShare != nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let map = UIGraphicsImageRenderer(size: ShareCard.mapSize, format: format).image { renderer in
            UIColor(red: 0.1, green: 0.3, blue: 0.2, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: ShareCard.mapSize))
        }
        var dimensions: [CGSize] = []
        for scheme in [ColorScheme.light, .dark] {
            let rendered = try XCTUnwrap(ShareCardRenderer.render(
                profile: profile, trend: trend, baseline: nil, map: map, colorScheme: scheme))
            let url = try XCTUnwrap(ShareCardRenderer.write(rendered, for: profile))
            defer { try? FileManager.default.removeItem(at: url) }
            let png = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
            let (bytes, width, height) = try pixels(png)
            dimensions.append(CGSize(width: width, height: height))
            XCTAssertEqual(width, 1200)
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
                          "PNG contains transparent pixels that a recipient can flatten to white")
            let mapPixel = Array(bytes[(50 * width + width / 2) * 4 ..< (50 * width + width / 2) * 4 + 4])
            for x in [0, width / 2, width - 1] {
                let top = Array(bytes[x * 4 ..< x * 4 + 4])
                XCTAssertEqual(top, mapPixel, "Map must reach the full top edge without a stock strip")
                let offset = ((height - 1) * width + x) * 4
                let brightness = Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 765
                if scheme == .dark { XCTAssertLessThan(brightness, 0.25) }
                else { XCTAssertGreaterThan(brightness, 0.85) }
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "export-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(dimensions.first, dimensions.last, "Appearance must not change export geometry")
    }

    @MainActor
    func testElectionNullCardRendersOpaqueInBothAppearancesWithoutMap() throws {
        let profile = try XCTUnwrap(PrecinctDB.shared.precinct(unitID: "41005-:-X000")?.profile)
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(ShareCardRenderer.render(
                profile: profile, trend: [], baseline: nil, map: nil, colorScheme: scheme)?.cgImage)
            let (bytes, _, _) = try pixels(image)
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
            let brightness = Double(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])) / 765
            if scheme == .dark { XCTAssertLessThan(brightness, 0.25) }
            else { XCTAssertGreaterThan(brightness, 0.85) }
        }
    }

    private func pixels(_ image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }
}
