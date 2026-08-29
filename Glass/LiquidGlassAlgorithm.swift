// Copyright © 2026 Zdenko. All rights reserved.
//
// LiquidGlassAlgorithm
// ====================
//
// Pure-Swift translation of the GLSL reference shader supplied with the
// integration request. Every numeric formula in this file is a
// line-for-line port of the shader (no AppKit / CoreImage / GPU calls
// here) so the algorithm is unit-testable on a stock macOS install
// without a display, OpenGL, or Metal.
//
// Original GLSL reference (verbatim):
//
//     #define width 0.33
//     #define height 0.33
//     #define radius 0.1
//     #define lens_refraction 0.1
//     #define sharp 0.1
//
//     float _clamp(float a){ return clamp(a,0.,1.); }
//
//     float box(in vec2 p, in vec2 b, in vec4 r) { … }
//
//     void mainImage(out vec4 fragColor, in vec2 fragCoord) {
//         fragColor = vec4(0);
//         vec2 ir = iResolution.xy;
//         vec2 wh = vec2(width, height)/2.0*ir.x/ir.y;
//         vec4 vr = vec4(radius)/2.0*ir.x/ir.y;
//         vec2 uv = fragCoord/ir;
//         vec2 mouse = iMouse.xy;
//         if (length(mouse)<1.0) { mouse = ir/2.0; }
//         vec2 m2 = (uv - mouse/ir);
//
//         float rb1 =  _clamp(-box(vec2(m2.x*ir.x/ir.y,m2.y), wh, vr)/sharp*32.0);
//         float rb2 =  _clamp(-box(…, wh+1.0/ir.y, vr)/sharp*16.0) - _clamp(-box(…, wh, vr)/sharp*16.0);
//         float rb3 = _clamp(-box(…, wh+4.0/ir.y, vr)/sharp*4.0) - _clamp(-box(…, wh-4.0/ir.y, vr)/sharp*4.0);
//
//         float transition = smoothstep(0.0, 1.0, rb1);
//
//         if (transition>0.0) {
//             vec2 lens = (uv-0.5)*sin(pow(_clamp(-box(…, wh, vr)/lens_refraction), 0.25)*1.57)+0.5;
//             /* 9×9 box blur of `texture(iChannel0, lens+blur)` */
//             float total = 0.0;
//             for (float x = -4.0; x <= 4.0; x++) {
//                 for (float y = -4.0; y <= 4.0; y++) {
//                     vec2 blur = vec2(x, y) * 0.5 / ir;
//                     fragColor += texture(iChannel0, lens+blur);
//                     total += 1.0;
//                 }
//             } fragColor/=total;
//
//             float gradient = _clamp(clamp(m2.y,0.0,0.2)+0.1)/2.0
//                            + _clamp(clamp(-m2.y,-1.0,0.2)*rb3+0.1)/2.0;
//             vec4 lighting = fragColor+1.0*vec4(rb2)+gradient*1.0;
//             fragColor = mix(texture(iChannel0, uv), lighting, transition);
//         } else {
//             fragColor = texture(iChannel0, uv);
//         }
//     }
//
// The Swift port keeps the *exact* numeric definitions:
//
//   - `LiquidGlassBoxSDF.box(p:b:r:)`           ↔ `float box(in vec2 p, in vec2 b, in vec4 r)`
//   - `LiquidGlassAlgorithm.transitionMask(...)`  ↔ the three `rb*` lines + `smoothstep`
//   - `LiquidGlassAlgorithm.lensDisplacement(...)` ↔ the `sin(pow(...,0.25)*1.57)` warp
//   - `LiquidGlassAlgorithm.blurKernel`           ↔ the 9×9 box-blur tap grid
//   - `LiquidGlassAlgorithm.lighting(...)`        ↔ the gradient + rb2 lighting term
//   - `LiquidGlassAlgorithm.evaluate(uv:)`        ↔ the full per-pixel pipeline
//
// A `LiquidGlassRendering` protocol exposes a `makeFilterChain(parameters:)`
// hook for the CoreImage renderer (`LiquidGlassRenderer`) so the same
// parameters drive both the pure-Swift compute path and the GPU path.

import Foundation
import CoreGraphics
import simd

// MARK: - Parameters

/// All five shader constants, plus the two surface dimensions the shader
/// derives from `iResolution.xy`. Stored as value type; `Sendable` so
/// the renderer can hand it across actor boundaries.
public struct LiquidGlassParameters: Equatable, Sendable {

    /// `width` in the shader — fraction of the horizontal axis occupied
    /// by the panel. Validated to `0.0 ... 1.0`.
    public var width: Double

    /// `height` — fraction of the (aspect-corrected) horizontal axis
    /// occupied by the panel. Validated to `0.0 ... 1.0`.
    public var height: Double

    /// `radius` — uniform corner radius expressed as a fraction of the
    /// panel's short edge. The shader applies this *after* the
    /// `ir.x/ir.y` aspect correction; we preserve that step in the
    /// renderer. Validated to `0.0 ... 0.5`.
    public var radius: Double

    /// `lens_refraction` — divisor applied to the inside-SDF before
    /// the `pow(_, 0.25) * 1.57` lens-warping step. The shader uses it
    /// as a divisor; lower values = stronger lens. We store the raw
    /// value (the algorithm and renderer share the same formula).
    /// Validated to `0.001 ... 1.0` to avoid div-by-zero.
    public var lensRefraction: Double

    /// `sharp` — divisor applied to the inside-SDF to derive the
    /// transition mask. Lower values = softer edge. Validated to
    /// `0.001 ... 1.0` to avoid div-by-zero.
    public var sharpness: Double

    /// Aspect-corrected horizontal resolution, in points. Replaces
    /// `iResolution.x` from the shader. Must be > 0.
    public var resolutionX: Double

    /// Vertical resolution, in points. Replaces `iResolution.y`. Must
    /// be > 0.
    public var resolutionY: Double

    /// Default-argument constructor with validation. The initializer
    /// is the only public entry point; `width` / `height` etc. that
    /// arrive out of range are silently clamped to the supported
    /// range so a UI slider that pushes a value past its bound can
    /// never crash the renderer.
    public init(
        width: Double = 0.33,
        height: Double = 0.33,
        radius: Double = 0.10,
        lensRefraction: Double = 0.10,
        sharpness: Double = 0.10,
        resolutionX: Double = 800,
        resolutionY: Double = 600
    ) {
        self.width = Self.clamp(width, 0.0, 1.0)
        self.height = Self.clamp(height, 0.0, 1.0)
        self.radius = Self.clamp(radius, 0.0, 0.5)
        self.lensRefraction = Self.clamp(lensRefraction, 0.001, 1.0)
        self.sharpness = Self.clamp(sharpness, 0.001, 1.0)
        self.resolutionX = max(1, resolutionX)
        self.resolutionY = max(1, resolutionY)
    }

    /// `width`, `height`, `radius` defaults exactly as the shader.
    public static let `default` = LiquidGlassParameters()

    /// Documented clamp helper. Reused by `validateRanges(_:)` so the
    /// renderer can normalize a parameters struct that originated
    /// from an external (untrusted) source — for example user input
    /// or a saved preference file.
    public static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(hi, Swift.max(lo, value))
    }
}

// MARK: - Box SDF

/// Rounded-rectangle signed distance function. Direct port of the
/// GLSL `box(...)` helper. `p` is the query point, `b` is the
/// half-extent, `r` is a 4-component per-corner radius encoded as
/// `(top-left, top-right, bottom-left, bottom-right)`. The shader
/// only ever uses a uniform `vec4(radius)`; the per-corner encoding
/// is preserved for fidelity to the original (a real rounded-rect
/// with non-uniform corners would slot in here).
public enum LiquidGlassBoxSDF {

    /// Pure function: signed distance to a rounded rectangle. Matches
    /// the GLSL formula in `iResolution` units.
    @inlinable
    public static func box(
        p: SIMD2<Double>,
        b: SIMD2<Double>,
        r: SIMD4<Double>
    ) -> Double {
        // The shader does: r.xy = (p.x>0.0) ? r.xy : r.zw; r.x = (p.y>0.0)
        // ? r.x : r.y;  … i.e. the corner radius is selected from the
        // 4-tuple by the sign of p. We mirror that exactly.
        let rxy: SIMD2<Double> = p.x > 0 ? SIMD2<Double>(r.x, r.y) : SIMD2<Double>(r.z, r.w)
        let rsel: Double = p.y > 0 ? rxy.x : rxy.y
        let q = SIMD2<Double>(abs(p.x) - b.x + rsel, abs(p.y) - b.y + rsel)
        return Swift.min(Swift.max(q.x, q.y), 0) + (q.max(by: 0)).length() - rsel
    }
}

// MARK: - Algorithm

/// Pure-Swift realization of the GLSL `mainImage` logic. Every public
/// method here is a port of a GLSL expression and is unit-tested
/// against the original numeric outputs (see
/// `LiquidGlassAlgorithmTests`).
public enum LiquidGlassAlgorithm {

    // MARK: - Derived inputs (shader lines 18–22)

    /// `vec2 wh = vec2(width, height) / 2.0 * ir.x / ir.y` — half-extent
    /// in the aspect-corrected coordinate space the shader works in.
    @inlinable
    public static func halfExtent(of p: LiquidGlassParameters) -> SIMD2<Double> {
        let aspect = p.resolutionX / p.resolutionY
        return SIMD2<Double>(p.width, p.height) * 0.5 * aspect
    }

    /// `vec4 vr = vec4(radius) / 2.0 * ir.x / ir.y` — corner radius
    /// in the same space. `SIMD4(r, r, r, r)` for uniform corners.
    @inlinable
    public static func cornerRadii(of p: LiquidGlassParameters) -> SIMD4<Double> {
        let aspect = p.resolutionX / p.resolutionY
        let r = p.radius * 0.5 * aspect
        return SIMD4<Double>(r, r, r, r)
    }

    /// Convert a UV in `[0,1]²` (origin at top-left, same as the
    /// shader) into the shader's aspect-corrected local coordinates
    /// centered on the panel.
    @inlinable
    public static func localPoint(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> SIMD2<Double> {
        // Shader: `vec2 m2 = (uv - mouse/ir)` then uses `(m2.x*ir.x/ir.y, m2.y)`.
        // `mouse/ir` == `anchor` because `iMouse.xy / iResolution.xy == anchor`.
        let m2 = uv - anchor
        return SIMD2<Double>(m2.x * p.resolutionX / p.resolutionY, m2.y)
    }

    // MARK: - rb1, rb2, rb3 (transition + edge + gradient)

    /// `float rb1 = _clamp(-box(…)/sharp*32.0)` — base inside-mask.
    @inlinable
    public static func rb1(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> Double {
        let local = localPoint(uv: uv, anchor: anchor, parameters: p)
        let wh = halfExtent(of: p)
        let vr = cornerRadii(of: p)
        let d = LiquidGlassBoxSDF.box(p: local, b: wh, r: vr)
        return saturate(-d / p.sharpness * 32.0)
    }

    /// `float rb2 = _clamp(…) - _clamp(…)` — the 1-px border ring.
    @inlinable
    public static func rb2(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> Double {
        let local = localPoint(uv: uv, anchor: anchor, parameters: p)
        let wh = halfExtent(of: p)
        let vr = cornerRadii(of: p)
        let outer = LiquidGlassBoxSDF.box(
            p: local,
            b: wh + SIMD2<Double>(repeating: 1.0 / p.resolutionY),
            r: vr
        )
        let inner = LiquidGlassBoxSDF.box(p: local, b: wh, r: vr)
        return saturate(-outer / p.sharpness * 16.0) - saturate(-inner / p.sharpness * 16.0)
    }

    /// `float rb3 = _clamp(…) - _clamp(…)` — the 4-px gradient ring.
    @inlinable
    public static func rb3(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> Double {
        let local = localPoint(uv: uv, anchor: anchor, parameters: p)
        let wh = halfExtent(of: p)
        let vr = cornerRadii(of: p)
        let outer = LiquidGlassBoxSDF.box(
            p: local,
            b: wh + SIMD2<Double>(repeating: 4.0 / p.resolutionY),
            r: vr
        )
        let inner = LiquidGlassBoxSDF.box(
            p: local,
            b: wh - SIMD2<Double>(repeating: 4.0 / p.resolutionY),
            r: vr
        )
        return saturate(-outer / p.sharpness * 4.0) - saturate(-inner / p.sharpness * 4.0)
    }

    /// `float transition = smoothstep(0.0, 1.0, rb1)`.
    @inlinable
    public static func transition(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> Double {
        smoothstep(0, 1, rb1(uv: uv, anchor: anchor, parameters: p))
    }

    // MARK: - Lens displacement

    /// `vec2 lens = (uv-0.5)*sin(pow(_clamp(-box(…)/lens_refraction), 0.25)*1.57)+0.5`.
    @inlinable
    public static func lensDisplacement(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> SIMD2<Double> {
        let local = localPoint(uv: uv, anchor: anchor, parameters: p)
        let wh = halfExtent(of: p)
        let vr = cornerRadii(of: p)
        let d = LiquidGlassBoxSDF.box(p: local, b: wh, r: vr)
        let inner = saturate(-d / p.lensRefraction)
        let phase = pow(inner, 0.25) * 1.57        // 1.57 ≈ π/2
        let sine = SIMD2<Double>(repeating: sin(phase))
        return (uv - SIMD2<Double>(repeating: 0.5)) * sine + SIMD2<Double>(repeating: 0.5)
    }

    // MARK: - Blur kernel

    /// 9×9 box-blur taps (raw `vec2(x, y)`); `evaluate` applies the shader's
    /// `* 0.5 / ir` scale per pixel, so the composite offset is `vec2(x, y) * 0.5 / ir`.
    public static let blurKernel: [SIMD2<Double>] = {
        var taps: [SIMD2<Double>] = []
        taps.reserveCapacity(81)
        for ix in -4...4 {
            for iy in -4...4 {
                let x = Double(ix)
                let y = Double(iy)
                taps.append(SIMD2<Double>(x, y))
            }
        }
        return taps
    }()

    // MARK: - Lighting

    /// `float gradient = _clamp(clamp(m2.y,0,0.2)+0.1)/2.0
    ///               + _clamp(clamp(-m2.y,-1,0.2)*rb3+0.1)/2.0`.
    @inlinable
    public static func lighting(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters
    ) -> Double {
        let m2 = uv - anchor
        let top = saturate(saturate(m2.y, 0, 0.2) + 0.1) / 2.0
        let bottom = saturate(saturate(-m2.y, -1, 0.2) * rb3(uv: uv, anchor: anchor, parameters: p) + 0.1) / 2.0
        return top + bottom
    }

    // MARK: - Composite

    /// Per-pixel pipeline. `sample(uv:)` is the host's image lookup
    /// (returns a `SIMD4<Float>` RGBA in linear space). The result is
    /// the same RGBA the shader writes to `fragColor`.
    ///
    /// Pure function: the same `parameters` and `sample` closure
    /// always produce the same output, which is what makes the
    /// unit-test golden vectors deterministic.
    public static func evaluate(
        uv: SIMD2<Double>,
        anchor: SIMD2<Double>,
        parameters p: LiquidGlassParameters,
        sample: (SIMD2<Double>) -> SIMD4<Float>
    ) -> SIMD4<Float> {
        let t = transition(uv: uv, anchor: anchor, parameters: p)
        guard t > 0 else { return sample(uv) }
        let lens = lensDisplacement(uv: uv, anchor: anchor, parameters: p)
        // 9×9 box blur. We accumulate in `Float` for the renderer to
        // round-trip through `CIFilter` losslessly; the GLSL shader
        // works in `float` (32-bit) too, so this is a faithful port.
        var acc = SIMD4<Float>(repeating: 0)
        for tap in blurKernel {
            let sampleUV = lens + tap * SIMD2<Double>(
                0.5 / p.resolutionX, 0.5 / p.resolutionY
            )
            acc += sample(sampleUV)
        }
        let blurred = acc / Float(blurKernel.count)
        let grad = Float(lighting(uv: uv, anchor: anchor, parameters: p))
        let rb2v = Float(rb2(uv: uv, anchor: anchor, parameters: p))
        let lighting_ = blurred + SIMD4<Float>(repeating: rb2v) + SIMD4<Float>(repeating: grad)
        let original = sample(uv)
        return mix(original, lighting_, Float(t))
    }

    // MARK: - math helpers

    /// GLSL `clamp(x, lo, hi)` for `Double`.
    @inlinable
    public static func saturate(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        Swift.min(hi, Swift.max(lo, x))
    }

    /// GLSL `smoothstep(edge0, edge1, x)` for `Double`. Identical
    /// formula to the GLSL spec (`t = clamp((x-edge0)/(edge1-edge0), 0, 1); return t*t*(3-2*t)`).
    @inlinable
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = saturate((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// GLSL `mix(a, b, t)` for `SIMD4<Float>`.
    @inlinable
    public static func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }
}

// MARK: - Rendering protocol

/// Renderer-agnostic entry point. `LiquidGlassRenderer` (CoreImage)
/// implements this for production; tests can provide a stub that
/// captures the last `parameters` for assertion.
public protocol LiquidGlassRendering: AnyObject, Sendable {

    /// Build a list of CoreImage filters that approximate the GLSL
    /// pipeline for the supplied parameters. The first filter is
    /// applied to the source image; subsequent filters form a chain.
    /// `resolution` is the source image's size in pixels.
    ///
    /// Implementations MUST be safe to call from any thread. They
    /// MUST NOT mutate `parameters` and MUST return a fresh array
    /// every call (no shared mutable state).
    func makeFilterChain(
        parameters: LiquidGlassParameters,
        resolution: CGSize
    ) -> [Any]
}

extension SIMD2 where Scalar == Double {
    /// `.max(by: 0)` (component-wise max with 0) — the GLSL
    /// `max(q, 0.0)` step. Named to match the original expression.
    @inlinable
    public func max(by: Double) -> SIMD2<Double> {
        SIMD2<Double>(Swift.max(x, by), Swift.max(y, by))
    }
    /// Component-wise length.
    @inlinable
    public func length() -> Double {
        sqrt(x * x + y * y)
    }
}
