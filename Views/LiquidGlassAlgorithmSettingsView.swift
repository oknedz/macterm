// Copyright © 2026 Zdenko. All rights reserved.
//
// LiquidGlassAlgorithmSettingsView
// ================================
//
// Additive SwiftUI Settings panel for the Liquid Glass algorithm.
// Reads/writes a `LiquidGlassParameters` value held in `@State`,
// which is also the value the live `LiquidGlassGlassView` reads
// from. The view exposes all five shader constants plus the panel
// dimensions. No coupling to `TerminalController`, `SettingsView`,
// or any other existing module.
//
// Anyone can mount this view anywhere:
//   - in the existing `Settings` scene via SwiftUI's
//     `SettingsLink` (the existing SettingsRoot is untouched),
//   - as a sheet,
//   - in a unit test host.
//
// The view is fully value-typed and `Sendable`; the only side
// effect is a per-pixel update on the preview which is itself
// driven by the same `LiquidGlassAlgorithm` that production code
// uses, so what you see is what the renderer produces.

import SwiftUI
import AppKit

/// Self-contained SwiftUI Settings card for the Liquid Glass
/// algorithm. No dependencies on existing modules.
public struct LiquidGlassAlgorithmSettingsView: View {

    /// The initial parameters. The view owns a `@State` copy so
    /// changes are immediate (every keystroke updates the live
    /// preview). The caller's reference is *not* mutated; use
    /// `onCommit` to persist or push the final value upstream.
    @State public var parameters: LiquidGlassParameters
    public let onCommit: ((LiquidGlassParameters) -> Void)?

    /// Convenience: default-init with the documented shader values.
    public init(parameters: LiquidGlassParameters = .default,
                onCommit: ((LiquidGlassParameters) -> Void)? = nil) {
        _parameters = State(initialValue: parameters)
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Live preview that runs the same algorithm the renderer
            // uses. Mounted via `LiquidGlassGlassView` (the public
            // SwiftUI surface) so what the user sees here is exactly
            // what shows up at runtime.
            LiquidGlassGlassView(parameters: parameters, cornerRadius: 14)
                .frame(height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )

            // Numeric parameter sliders. Each binding goes through
            // `parameters`-as-binding via the per-param helpers
            // defined below.
            GroupBox("Panel") {
                paramRow("Width",
                         value: doubleBinding(\.width),
                         range: 0.05...1.0, step: 0.01,
                         format: { String(format: "%.2f", $0) })
                paramRow("Height",
                         value: doubleBinding(\.height),
                         range: 0.05...1.0, step: 0.01,
                         format: { String(format: "%.2f", $0) })
                paramRow("Corner Radius",
                         value: doubleBinding(\.radius),
                         range: 0.0...0.5, step: 0.01,
                         format: { String(format: "%.2f", $0) })
            }

            GroupBox("Lens") {
                paramRow("Refraction",
                         value: doubleBinding(\.lensRefraction),
                         range: 0.001...1.0, step: 0.01,
                         format: { String(format: "%.3f", $0) })
                paramRow("Sharpness",
                         value: doubleBinding(\.sharpness),
                         range: 0.001...1.0, step: 0.01,
                         format: { String(format: "%.3f", $0) })
            }

            GroupBox("Resolution") {
                paramRow("X (px)",
                         value: doubleBinding(\.resolutionX),
                         range: 64...4096, step: 32,
                         format: { String(format: "%.0f", $0) })
                paramRow("Y (px)",
                         value: doubleBinding(\.resolutionY),
                         range: 64...4096, step: 32,
                         format: { String(format: "%.0f", $0) })
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    parameters = .default
                }
                .controlSize(.small)
                Button("Apply") {
                    onCommit?(parameters)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bindings

    /// Build a `Binding<Double>` for a `parameters` key-path. Swift's
    /// `Binding(get:set:)` initializer lets us keep `parameters`
    /// `Equatable` (and `Sendable` if we ever want to pass it
    /// across actors) while still letting SwiftUI write into it.
    private func doubleBinding(_ keyPath: WritableKeyPath<LiquidGlassParameters, Double>) -> Binding<Double> {
        Binding(
            get: { parameters[keyPath: keyPath] },
            set: { parameters[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - Slider row

    @ViewBuilder
    private func paramRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 72, alignment: .trailing)
        }
    }
}
