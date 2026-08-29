import SwiftUI
import AppKit

/// Pill-shaped text field with the app's search-field focus styling: a subtle
/// gray fill and a <1pt border that brightens on focus. One shared component for
/// every search/filter field (Settings, sidebar, AI) so they read as one family.
struct PillTextField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage: String? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(focused ? Color(nsColor: .textBackgroundColor)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(focused ? Color(nsColor: .controlAccentColor).opacity(0.6)
                      : Color.primary.opacity(0.12),
                        lineWidth: focused ? 1 : 0.5)
        )
        .focused($focused)
    }
}

/// Convenience wrapper that prepends the search glyph.
struct PillSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        PillTextField(placeholder: placeholder, text: $text, systemImage: "magnifyingglass")
    }
}

/// Small info glyph that shows a styled tooltip on hover. Use at the end of a
/// setting label to explain what the control does.
struct InfoDot: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .help(text)
    }
}
