// Copyright © 2026 Zdenko. All rights reserved.
//
// LiquidGlassRasterizerTests
// ==========================
//
// Smoke tests for the working rendering path. The rasterizer is
// the only path that actually produces visible pixels (the
// `CALayer.backgroundFilters` path is a no-op on plain
// `CALayer` on macOS).

import XCTest
import CoreGraphics
@testable import macterm

final class LiquidGlassRasterizerTests: XCTestCase {

    /// Read an arbitrary (x, y) pixel from a CGImage into a
    /// freshly-allocated buffer.
    private func pixel(of cg: CGImage, at point: (x: Int, y: Int),
                       width: Int, height: Int) -> (UInt8, UInt8, UInt8) {
        let cs = CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: &buf, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let base = (point.y * width + point.x) * 4
        return (buf[base], buf[base + 1], buf[base + 2])
    }

    /// Two pixels are "different" if at least one channel differs.
    private func differs(_ a: (UInt8, UInt8, UInt8),
                         _ b: (UInt8, UInt8, UInt8)) -> Bool {
        return a.0 != b.0 || a.1 != b.1 || a.2 != b.2
    }

    func testRasterizerProducesNonNilImage() {
        let cg = LiquidGlassRasterizer.render(
            parameters: .default,
            size: CGSize(width: 64, height: 64)
        )
        XCTAssertNotNil(cg, "rasterizer must return a CGImage")
    }

    func testRasterizerProducesExpectedDimensions() {
        let size = CGSize(width: 80, height: 40)
        guard let cg = LiquidGlassRasterizer.render(
            parameters: .default, size: size
        ) else {
            XCTFail("rasterizer returned nil")
            return
        }
        XCTAssertEqual(cg.width, 80)
        XCTAssertEqual(cg.height, 40)
        XCTAssertEqual(cg.bitsPerComponent, 8)
        XCTAssertEqual(cg.bitsPerPixel, 32)
    }

    /// The default parameters place a 33%×33% panel at the center
    /// of the image. Inside the panel the algorithm applies a
    /// lens warp + 9×9 blur + lighting term, which MUST differ
    /// from the raw gradient sample outside the panel. If the
    /// center and corner pixels are identical, the algorithm is
    /// a no-op.
    func testRasterizerOutputDiffersInsideAndOutsidePanel() {
        let size = CGSize(width: 64, height: 64)
        guard let cg = LiquidGlassRasterizer.render(
            parameters: .default, size: size
        ) else {
            XCTFail("rasterizer returned nil")
            return
        }
        let center = pixel(of: cg, at: (32, 32), width: 64, height: 64)
        let outside = pixel(of: cg, at: (1, 1), width: 64, height: 64)
        XCTAssertTrue(
            differs(center, outside),
            "panel interior and exterior render identically — algorithm is a no-op (center=\(center), outside=\(outside))"
        )
    }

    /// Compare TWO POINTS that both fall inside the panel. The
    /// first uses the default 33% panel; the second uses a
    /// 90% panel. We sample at the geometric edge of the 33%
    /// panel — inside the 33% panel but on the boundary of the
    /// 90% panel's edge handling. The lens warp at the edge is
    /// at maximum sensitivity to `lensRefraction` and `radius`,
    /// so the two images MUST differ.
    func testRasterizerRespondsToParameterChanges() {
        let a = LiquidGlassParameters.default
        let b = LiquidGlassParameters(
            width: 0.9, height: 0.9, radius: 0.45,
            lensRefraction: 0.5, sharpness: 0.5,
            resolutionX: 64, resolutionY: 64
        )
        let size = CGSize(width: 64, height: 64)
        guard let cgA = LiquidGlassRasterizer.render(parameters: a, size: size),
              let cgB = LiquidGlassRasterizer.render(parameters: b, size: size)
        else {
            XCTFail("rasterizer returned nil")
            return
        }
        // (40, 32) is near the right edge of the 33%×33% panel
        // (which spans x∈[21,42]). The 90% panel (x∈[3,60])
        // also covers this point but with very different
        // parameters.
        let pA = pixel(of: cgA, at: (40, 32), width: 64, height: 64)
        let pB = pixel(of: cgB, at: (40, 32), width: 64, height: 64)
        XCTAssertTrue(
            differs(pA, pB),
            "rasterizer did not respond to parameter changes (a=\(pA), b=\(pB))"
        )
    }
}
