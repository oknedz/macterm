// Copyright © 2026 Zdenko. All rights reserved.
//
// LiquidGlassGlassView
// ===================
//
// SwiftUI + AppKit entry points for the Liquid Glass algorithm.
//
// Two surfaces, both purely additive:
//
//   1. `LiquidGlassGlassView` (SwiftUI): a self-contained view that
//      renders a single Liquid Glass panel by rasterizing
//      `LiquidGlassAlgorithm.evaluate(...)` into a `CGImage` and
//      displaying it via `NSImageView`. The rasterizer runs the
//      exact pure-Swift port of the GLSL reference shader per
//      pixel, so the output is bit-for-bit the same as the
//      reference (modulo raster quantization).
//
//   2. `LiquidGlassNSView` (AppKit): an `NSView` subclass that
//      hosts an `NSImageView` and updates it when the parameters
//      change. Use inside an `NSHostingController`,
//      `NSViewController`, or any raw AppKit host.
//
// All UI updates are confined to the main thread. The CIFilter
// chain in `LiquidGlassRenderer` is also available via
// `LiquidGlassCIFilterHostView` for hosts that compose against a
// backing layer with content behind it.
//
// IMPORTANT: the previous default path (`CALayer.backgroundFilters`)
// has been replaced. Plain `CALayer` does not honor
// `backgroundFilters` on macOS, so that path produced no visible
// output. The new default rasterizes the algorithm to a real
// `CGImage` via the pure-Swift path (which the unit tests already
// cover) and shows it on an `NSImageView`.

import SwiftUI
import AppKit
import CoreImage
import CoreGraphics
import Quartz

// MARK: - CPU rasterizer (the working renderer)

/// CPU-side rasterizer for the Liquid Glass algorithm. Runs the
/// pure-Swift `LiquidGlassAlgorithm.evaluate(_:)` per pixel and
/// writes the result to a `CGImage`. This is the path that
/// actually produces visible pixels.
public struct LiquidGlassRasterizer: Sendable {

    /// Render the algorithm into a CGImage of the given size.
    /// `sample(uv:)` is the host's image lookup (RGBA in `[0,1]`,
    /// linear); the default returns a synthetic gradient so the
    /// output is self-evident on any host.
    public static func render(
        parameters: LiquidGlassParameters,
        size: CGSize,
        sample: @escaping @Sendable (SIMD2<Double>) -> SIMD4<Float> = LiquidGlassRasterizer.gradientSample
    ) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let count = w * h
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let anchor = SIMD2<Double>(0.5, 0.5)
        // Parallel rasterization: split the image into horizontal
        // strips and process each strip on a background queue.
        let strips = max(1, min(8, h / 16))
        let stripHeight = h / strips
        DispatchQueue.concurrentPerform(iterations: strips) { strip in
            let yStart = strip * stripHeight
            let yEnd = (strip == strips - 1) ? h : yStart + stripHeight
            for y in yStart..<yEnd {
                for x in 0..<w {
                    let uv = SIMD2<Double>(Double(x) / Double(max(w - 1, 1)),
                                           Double(y) / Double(max(h - 1, 1)))
                    let rgba = LiquidGlassAlgorithm.evaluate(
                        uv: uv, anchor: anchor,
                        parameters: parameters, sample: sample
                    )
                    let base = (y * w + x) * 4
                    bytes[base + 0] = floatToByte(rgba.x)
                    bytes[base + 1] = floatToByte(rgba.y)
                    bytes[base + 2] = floatToByte(rgba.z)
                    bytes[base + 3] = floatToByte(rgba.w)
                }
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Default sample: a smooth blue→purple→pink→orange gradient
    /// so the algorithm output is visible without a backing image.
    @Sendable
    public static func gradientSample(_ uv: SIMD2<Double>) -> SIMD4<Float> {
        let t = uv.x * 0.6 + uv.y * 0.4
        let r = Float(0.55 + 0.40 * sin(t * .pi * 2))
        let g = Float(0.40 + 0.35 * sin((t + 0.30) * .pi * 2))
        let b = Float(0.70 + 0.30 * sin((t + 0.60) * .pi * 2))
        return SIMD4<Float>(r, g, b, 1.0)
    }

    /// Linear float → 8-bit. Clamps out-of-range values.
    private static func floatToByte(_ v: Float) -> UInt8 {
        let clamped = Swift.max(0, Swift.min(1, v))
        return UInt8((clamped * 255).rounded())
    }
}

// MARK: - SwiftUI

/// SwiftUI surface that draws a single Liquid Glass panel by
/// rasterizing the algorithm into a CGImage and displaying it.
public struct LiquidGlassGlassView: View {
    public let parameters: LiquidGlassParameters
    public let cornerRadius: CGFloat

    public init(parameters: LiquidGlassParameters = .default,
                cornerRadius: CGFloat = 14) {
        self.parameters = parameters
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        LiquidGlassNSViewRepresentable(parameters: parameters,
                                       cornerRadius: cornerRadius)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// Internal SwiftUI→AppKit bridge. Owns a single `LiquidGlassNSView`
/// instance and forwards parameter updates to it.
private struct LiquidGlassNSViewRepresentable: NSViewRepresentable {
    let parameters: LiquidGlassParameters
    let cornerRadius: CGFloat

    @MainActor
    func makeNSView(context: Context) -> LiquidGlassNSView {
        let v = LiquidGlassNSView(frame: .zero)
        v.applyParameters(parameters, cornerRadius: cornerRadius)
        return v
    }

    @MainActor
    func updateNSView(_ nsView: LiquidGlassNSView, context: Context) {
        nsView.applyParameters(parameters, cornerRadius: cornerRadius)
    }
}

// MARK: - AppKit (working path: NSImageView + CGImage)

/// AppKit surface. The view hosts an `NSImageView` whose
/// `image` is the rasterized output of `LiquidGlassRasterizer`.
@MainActor
public final class LiquidGlassNSView: NSView {

    public let imageView: NSImageView

    private var cached: LiquidGlassParameters?
    private var cachedRadius: CGFloat = -1
    private var cachedSize: CGSize = .zero
    private var generation: UInt64 = 0

    public override init(frame frameRect: NSRect) {
        self.imageView = NSImageView(frame: .zero)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        addSubview(imageView)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    public func applyParameters(_ p: LiquidGlassParameters, cornerRadius: CGFloat) {
        let size = bounds.size
        if let cached,
           cached == p,
           cachedRadius == cornerRadius,
           cachedSize == size,
           imageView.image != nil {
            return
        }
        cached = p
        cachedRadius = cornerRadius
        cachedSize = size
        generation &+= 1
        let myGen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cg = LiquidGlassRasterizer.render(
                parameters: p, size: size
            ) else { return }
            let image = NSImage(cgImage: cg, size: size)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == myGen else { return }
                self.imageView.image = image
            }
        }
    }

    public override func layout() {
        super.layout()
        imageView.frame = bounds
        if let cached {
            applyParameters(cached, cornerRadius: cachedRadius)
        }
    }
}

// MARK: - Optional CIFilter path (preserved for advanced hosts)

/// The `CALayer.backgroundFilters` path, kept for callers that
/// compose this view against a backing layer with real content
/// behind it. On a plain `CALayer` this is a no-op on macOS —
/// `LiquidGlassNSView` is the working default.
@MainActor
public final class LiquidGlassCIFilterHostView: NSView {
    public let renderer: LiquidGlassRenderer

    private var cached: LiquidGlassParameters?
    private var cachedRadius: CGFloat = -1

    public init(renderer: LiquidGlassRenderer? = nil) {
        self.renderer = renderer ?? LiquidGlassRenderer()
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.actions = [:]
        layer?.needsDisplayOnBoundsChange = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    public func applyParameters(_ p: LiquidGlassParameters, cornerRadius: CGFloat) {
        if cached == p && cachedRadius == cornerRadius { return }
        cached = p
        cachedRadius = cornerRadius
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        let chain = renderer.makeFilterChain(parameters: p, resolution: bounds.size)
        layer?.backgroundFilters = chain.compactMap { $0 as? CIFilter }
    }

    public override func layout() {
        super.layout()
        if let cached {
            applyParameters(cached, cornerRadius: cachedRadius)
        }
    }
}
