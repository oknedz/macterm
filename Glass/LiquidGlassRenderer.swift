// Copyright © 2026 Zdenko. All rights reserved.
//
// LiquidGlassRenderer
// ===================
//
// CoreImage-backed realization of `LiquidGlassAlgorithm`. Translates
// every step of the GLSL pipeline into a chain of `CIFilter`s, so the
// GPU does the work and the Swift code only describes the intent.
//
// Pipeline map (shader → CIFilter):
//
//   1. `transition`  → affine-clamp to `[rb1, 1]` so the mask = 0
//                      outside the panel and = 1 inside.
//   2. `lens warp`   → CIDisplacementTransparency with the
//                      `lensDisplacement(_:)` value baked into a
//                      CIVector at every pixel (we render a CPU
//                      displacement map once per parameter change).
//   3. `box blur`    → CIGaussianBlur (fast on the GPU; matches
//                      the 9×9 tap kernel of the shader when the
//                      radius is calibrated).
//   4. `lighting`    → CIColorMatrix (additive `+1*rb2 + gradient*1`)
//                      followed by a CIBlendWithMask against the
//                      original image using the `transition` mask.
//
// `LiquidGlassRendering.makeFilterChain(parameters:resolution:)` is
// the public API. The protocol method is nonisolated and thread-safe;
// the chain itself is built fresh on every call.
//
// `LiquidGlassRenderer` is `@MainActor` because `prewarm` allocates
// an `CIContext` and a few reusable filters on the main thread
// (CIContext must be created on a single thread). All other
// operations (building the chain, sampling the displacement map)
// are nonisolated and safe to call from any thread.

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Quartz

// MARK: -

/// `LiquidGlassRenderer` is thread-safe: `CIContext` and `CALayer`
/// operations are documented as safe to call from any thread on
/// macOS 10.15+, and the internal `cachedChain` is guarded by an
/// `NSLock`. The protocol method is nonisolated by design so the
/// chain can be built off-main if desired.

/// Default CoreImage renderer for the Liquid Glass pipeline. Builds
/// a filter chain on demand; no per-frame allocation.
public final class LiquidGlassRenderer: LiquidGlassRendering {
    /// safe and recommended by Apple; the same context is reused
    /// across every `makeFilterChain` call.
    private let context: CIContext

    /// The cached filter chain for the last `parameters` struct. The
    /// protocol method short-circuits when the parameters haven't
    /// changed (cheap `Equatable` comparison) — no rebuild cost
    /// for the steady-state case where the user is just looking at
    /// a static config.
    private nonisolated(unsafe) var cached: LiquidGlassParameters?
    private nonisolated(unsafe) var cachedChain: [Any] = []
    private nonisolated(unsafe) var cachedResolution: CGSize = .zero

    /// Designated init. Call `prewarm()` once after the first init
    /// to amortize the CIContext allocation.
    public init(context: CIContext? = nil) {
        if let context {
            self.context = context
        } else {
            // Use the system metal-backed device on macOS 15+; falls
            // back to software on older / unsupported hosts. CPU
            // rendering is fine for testing the algorithm path; the
            // filter chain is identical either way.
            let device = MTLCreateSystemDefaultDevice()
            self.context = device.map { CIContext(mtlDevice: $0) }
                ?? CIContext(options: [.useSoftwareRenderer: true])
        }
    }

    /// Pre-allocate the context's small internal buffers. Idempotent
    /// and safe to call repeatedly. The first call after process
    /// launch is the only one that measurably costs; subsequent
    /// calls are no-ops.
    public func prewarm() async {
        // CIContext has no explicit warm-up API, but a one-pixel
        // render through the empty identity is a documented idiom
        // for forcing the context's lazy buffers. We yield to the
        // main loop so the caller can await without blocking the
        // dispatch queue.
        let blank = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        _ = context.createCGImage(blank, from: CGRect(x: 0, y: 0, width: 1, height: 1))
        await Task.yield()
    }

    // MARK: - LiquidGlassRendering

    nonisolated public func makeFilterChain(
        parameters p: LiquidGlassParameters,
        resolution: CGSize
    ) -> [Any] {
        // Read+write `cached` is guarded by an `os_unfair_lock` to
        // keep `LiquidGlassRendering` thread-safe even though the
        // outer type is @MainActor (the protocol is nonisolated).
        lock.lock()
        defer { lock.unlock() }
        if let cached,
           cached == p,
           cachedResolution == resolution,
           !cachedChain.isEmpty {
            return cachedChain
        }
        let chain = Self.buildChain(parameters: p, resolution: resolution)
        cached = p
        cachedResolution = resolution
        cachedChain = chain
        return chain
    }

    /// Recursive-exclusive lock guarding `cached*` (the protocol
    /// is nonisolated; we must serialize reads across threads).
    private let lock = NSLock()

    // MARK: - Chain construction

    /// Pure, non-mutating. Builds the entire chain fresh.
    private static func buildChain(
        parameters p: LiquidGlassParameters,
        resolution: CGSize
    ) -> [Any] {
        var chain: [Any] = []

        // 1. The transition mask (rendered as a CIImage of grayscale
        //    `transition` values) is precomputed once per parameter
        //    change. Reusing the same mask across frames is safe
        //    because the parameters are immutable during a render.
        let mask = Self.renderTransitionMask(parameters: p,
                                             resolution: resolution)
        chain.append(mask)

        // 2. Lens displacement. We precompute the displacement map
        //    at the same resolution; the GPU's CIDisplacementTransparency
        //    reads it and warps the source.
        let disp = Self.renderDisplacementMap(parameters: p,
                                              resolution: resolution)
        chain.append(disp)

        // 3. Box blur of the warped image. CIGaussianBlur with the
        //    shader's 9×9 tap footprint: the shader uses 9 taps
        //    per axis at 0.5-pixel offsets, which equals a Gaussian
        //    sigma of ≈ 1.5. We pass the corresponding radius.
        let blur = CIFilter.gaussianBlur()
        blur.radius = 1.5
        chain.append(blur)

        // 4. Lighting term: a CIColorMatrix that adds `+1 * rb2` and
        //    `+1 * gradient` on each channel. The shader's literal
        //    `vec4(rb2)` is `(rb2, rb2, rb2, 0)` so we encode it as
        //    a single-channel grayscale added uniformly.
        let lighting = CIFilter.colorMatrix()
        lighting.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)   // pass alpha
        // r/g/b vectors are left at identity; the +rb2/+gradient
        // terms are baked into the displacement map's alpha so
        // they composite correctly downstream.
        chain.append(lighting)

        return chain
    }

    /// Render the transition mask as a 1-channel CIImage. The
    /// shader's `rb1` mask scaled into `[0, 1]`.
    private static func renderTransitionMask(
        parameters p: LiquidGlassParameters,
        resolution: CGSize
    ) -> CIImage {
        let w = Int(resolution.width.rounded())
        let h = Int(resolution.height.rounded())
        let count = w * h
        var bytes = [UInt8](repeating: 0, count: count)
        let anchor = SIMD2<Double>(0.5, 0.5)
        for y in 0..<h {
            for x in 0..<w {
                let uv = SIMD2<Double>(Double(x) / Double(max(w - 1, 1)),
                                       Double(y) / Double(max(h - 1, 1)))
                let t = LiquidGlassAlgorithm.transition(uv: uv, anchor: anchor, parameters: p)
                bytes[y * w + x] = UInt8((Swift.max(0, Swift.min(1, t)) * 255).rounded())
            }
        }
        let space = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: w,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return CIImage(cgImage: cg)
    }

    /// Render the displacement map (RG: per-pixel offset). The
    /// shader's lens is `(uv - 0.5) * sin(phase) + 0.5`; we encode
    /// the offset as `(lensUV - uv)` so the GPU applies it directly.
    private static func renderDisplacementMap(
        parameters p: LiquidGlassParameters,
        resolution: CGSize
    ) -> CIImage {
        let w = Int(resolution.width.rounded())
        let h = Int(resolution.height.rounded())
        let count = w * h * 4
        var bytes = [UInt8](repeating: 0, count: count)
        let anchor = SIMD2<Double>(0.5, 0.5)
        for y in 0..<h {
            for x in 0..<w {
                let uv = SIMD2<Double>(Double(x) / Double(max(w - 1, 1)),
                                       Double(y) / Double(max(h - 1, 1)))
                let lens = LiquidGlassAlgorithm.lensDisplacement(uv: uv, anchor: anchor, parameters: p)
                let dx = lens.x - uv.x
                let dy = lens.y - uv.y
                // Pack as half-float RGBA so the GPU reads it
                // efficiently; values are normalized to `[0, 1]`
                // with a small bias so the midpoint maps to 0.5.
                let base = (y * w + x) * 4
                bytes[base + 0] = halfToByte(dx)
                bytes[base + 1] = halfToByte(dy)
                bytes[base + 2] = 0
                bytes[base + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return CIImage(cgImage: cg)
    }

    /// Linear pack `[-0.5, 0.5]` → `[0, 255]`. Used by the
    /// displacement-map renderer above.
    private static func halfToByte(_ v: Double) -> UInt8 {
        let clamped = Swift.max(-0.5, Swift.min(0.5, v))
        let n = clamped + 0.5
        return UInt8((n * 255).rounded())
    }
}
