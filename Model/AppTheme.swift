import AppKit
import SwiftTerm

/// A complete color scheme sourced from NvChad's base46 engine
/// (https://github.com/NvChad/base46). One value drives the terminal palette,
/// the editor, the settings preview, and the whole app's appearance
/// (dark/light vibrancy + UI accent).
///
/// The raw catalog lives in the generated `NvChadThemes.swift`; this type adds
/// the derived colors and the SwiftTerm mapping.
struct AppTheme: Identifiable {
    /// base46 slug ("onedark") — also the persisted `themeName`.
    let slug: String
    let name: String
    let isDark: Bool
    /// UI accent (the theme's blue) for active controls / selection strokes.
    let accentHex: String
    /// Canonical base16 palette, index 0x0…0xF.
    let base16: [String]

    var id: String { slug }

    // MARK: - Terminal-facing colors

    /// base00 — the theme's real background.
    var background: NSColor { color(0x0) }
    /// base05 — default foreground.
    var foreground: NSColor { color(0x5) }
    /// base07 — brightest fg, keeps the caret visible over any content.
    var caret: NSColor { color(0x7) }
    /// base02 — base16 convention for selection background.
    var selection: NSColor { color(0x2) }
    var accent: NSColor { NSColor(hex: accentHex) ?? color(0xD) }

    /// The 16 ANSI slots in exactly NvChad/base46's own `term.lua` order:
    /// `01 08 0B 0A 0D 0E 0C 05 | 03 08 0B 0A 0D 0E 0C 07`
    /// (xterm slot order: black,red,…,white,brightBlack,…,brightWhite).
    var ansiColors: [SwiftTerm.Color] {
        Self.termLuaOrder.map { i in
            let (r, g, b) = rgb8(base16[i])
            // SwiftTerm's `red8:` slots are UInt16-typed (clamped to 0…255).
            return SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b))
        }
    }
    /// The same term.lua mapping as `ansiColors`, as NSColors — used by UI
    /// swatches (theme cards, live preview).
    var ansiSwatchColors: [NSColor] {
        Self.termLuaOrder.map(color)
    }

    /// Six vivid theme colors that cycle through the file-tree hierarchy:
    /// blue → cyan → green → yellow → magenta → red (term.lua ANSI slots),
    /// so folders/subfolders/files stay readable in EVERY theme.
    var hierarchyColors: [NSColor] {
        [4, 6, 2, 3, 5, 1].map { color(Self.termLuaOrder[$0]) }
    }
    /// Tint for a tree level (favorites root = 0).
    func hierarchyColor(level: Int) -> NSColor {
        hierarchyColors[abs(level) % hierarchyColors.count]
    }

    // MARK: - Editor syntax highlighting

    /// The bundled Highlightr scheme that best matches this base46 theme.
    /// Curated for the well-known pairs, keyword-based for families,
    /// dark/light fallback for everything else.
    var hljsTheme: String {
        switch slug {
        case "onedark", "doomchad", "pastelDark", "palenight":
            return "onedark"
        case "one_light", "onenord_light", "oceanic-light", "nano-light",
             "sunrise_breeze", "blossom_light":
            return "one-light"
        case "tokyonight":                       return "tokyo-night-dark"
        case "gruvbox", "gruvchad":              return "gruvbox-dark-medium"
        case "gruvbox_light":                    return "gruvbox-light-medium"
        case "nord", "onenord":                  return "nord"
        case "dracula", "chadracula", "chadracula-evondev":
            return "dracula"
        case "rosepine":                         return "rose-pine"
        case "rosepine-dawn":                    return "rose-pine-dawn"
        case "solarized_dark", "solarized_osaka": return "solarized-dark"
        case "solarized_light":                  return "solarized-light"
        case "github_dark":                      return "github-dark"
        case "github_light":                     return "github-light"
        case "nightowl":                         return "night-owl"
        case "material-darker", "material-deep-ocean":
            return "material-darker"
        case "material-lighter":                 return "material-lighter"
        case "oceanic-next":                     return "oceanicnext"
        case "darcula-dark", "jellybeans":       return "darcula"
        case "zenburn":                          return "zenburn"
        case "tomorrow_night":                   return "tomorrow-night"
        case "monochrome":                       return "grayscale-dark"
        case "oxocarbon":                        return "obsidian"
        case "vscode_dark":                      return "vs2015"
        case "vscode_light":                     return "vs"
        case "catppuccin-latte":                 return "one-light"
        default:
            if slug.contains("light") { return "one-light" }
            if slug.contains("catppuccin") { return "tokyo-night-dark" }
            if slug.contains("everforest") { return slug.contains("light") ? "atelier-forest-light" : "atelier-forest-dark" }
            return isDark ? "onedark" : "one-light"
        }
    }

    // MARK: - Catalog

    static let all: [AppTheme] = NvChadThemes.raw.map {
        AppTheme(slug: $0.slug, name: $0.name, isDark: $0.dark,
                 accentHex: $0.accent, base16: $0.base16)
    }
    static let defaultSlug = "onedark"
    static func bySlug(_ slug: String) -> AppTheme? {
        all.first { $0.slug == slug }
    }

    // MARK: - Helpers

    /// base46 lua/base46/term.lua ANSI-slot → base16 index.
    private static let termLuaOrder = [1, 8, 11, 10, 13, 14, 12, 5, 3, 8, 11, 10, 13, 14, 12, 15]

    private func color(_ index: Int) -> NSColor {
        NSColor(hex: base16[index]) ?? .black
    }
    private func rgb8(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }
}
