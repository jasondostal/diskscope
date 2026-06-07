import SwiftUI
import DiskScopeCore

/// A palette: per-category OKLCH color overrides (falling back to FilePalette's defaults),
/// the cushion ambient floor, and the canvas background. All app color lookups route through
/// the model's current palette, so switching themes retints the treemap, legend, and tree.
struct ThemePalette {
    var overrides: [FilePalette.Category: FilePalette.OKLCH]
    var ambient: Double
    var background: (r: Double, g: Double, b: Double)

    func oklch(forExt e: String) -> FilePalette.OKLCH {
        overrides[FilePalette.category(forExt: e)] ?? FilePalette.oklch(forExt: e)
    }
    func srgb(forExt e: String) -> (r: Double, g: Double, b: Double) { FilePalette.srgb(oklch(forExt: e)) }

    func oklch(_ cat: FilePalette.Category) -> FilePalette.OKLCH { overrides[cat] ?? FilePalette.oklch(cat) }
    func color(_ cat: FilePalette.Category) -> Color {
        let rgb = FilePalette.srgb(oklch(cat))
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
    var backgroundColor: Color { Color(.sRGB, red: background.r, green: background.g, blue: background.b) }

    /// Derive a variant of the default palette by scaling chroma / shifting lightness.
    static func variant(chroma: Double, lightness: Double = 0,
                        bg: (Double, Double, Double) = (0.043, 0.051, 0.063), ambient: Double = 0.58) -> ThemePalette {
        var o: [FilePalette.Category: FilePalette.OKLCH] = [:]
        for cat in FilePalette.Category.allCases {
            let b = FilePalette.oklch(cat)
            o[cat] = FilePalette.OKLCH(min(1, max(0, b.L + lightness)), max(0, b.C * chroma), b.H)
        }
        return ThemePalette(overrides: o, ambient: ambient, background: bg)
    }

    /// Build a fully-specified palette from a curated color scheme: every category maps to its
    /// own hex (converted into our OKLCH pipeline), plus a background hex. This is how the real
    /// themes get GENUINELY different hue families — not the same hues at different brightness.
    static func curated(_ map: [FilePalette.Category: String], bg: String, ambient: Double) -> ThemePalette {
        var o: [FilePalette.Category: FilePalette.OKLCH] = [:]
        for cat in FilePalette.Category.allCases where map[cat] != nil {
            o[cat] = FilePalette.oklch(hex: map[cat]!)
        }
        return ThemePalette(overrides: o, ambient: ambient, background: FilePalette.srgb(hex: bg))
    }
}

struct Theme: Identifiable {
    let id: String
    let name: String
    let palette: ThemePalette

    static let customID = "custom"

    static let presets: [Theme] = [
        // Spectrum — vivid even-spaced base (empty overrides use FilePalette's own colors).
        Theme(id: "spectrum", name: "Spectrum",
              palette: ThemePalette(overrides: [:], ambient: 0.58, background: FilePalette.srgb(hex: "0b0d10"))),
        // Cairn — near-black canvas with Cairn's "memory jellybean" colors (read from its
        // Memory-Type-Growth legend: code-snippet blue, debug/progress green, decision/research
        // amber, design/rule purple, learning crimson, note sky-blue).
        Theme(id: "cairn", name: "Cairn", palette: .curated([
            .code: "4d9bff",     // code-snippet blue
            .web: "2ed9c4",      // teal
            .image: "ff5d8f",    // rose
            .video: "ff4d6d",    // learning crimson
            .audio: "2ed99a",    // debug green
            .archive: "efa83a",  // decision amber
            .document: "b06bff", // design purple
            .data: "5ab0ff",     // note sky-blue
            .model: "d24dff",    // vivid magenta (his giants)
            .model3d: "7c6bff",  // indigo
            .binary: "ff8a3d",   // orange
            .system: "6b7280", .other: "8a8f9c",
        ], bg: "0a0a0c", ambient: 0.52)),
        // Dracula — purple/pink/cyan on charcoal.
        Theme(id: "dracula", name: "Dracula", palette: .curated([
            .code: "bd93f9", .web: "8be9fd", .image: "ff79c6", .video: "ff5555", .audio: "50fa7b",
            .archive: "f1fa8c", .document: "ffb86c", .data: "80d4ff", .model: "d68bff",
            .model3d: "7aa2ff", .binary: "ff8c5a", .system: "6272a4", .other: "8b90a8",
        ], bg: "282a36", ambient: 0.60)),
        // Catppuccin Mocha — soft pastels on deep mauve-black.
        Theme(id: "catppuccin", name: "Catppuccin", palette: .curated([
            .code: "89b4fa", .web: "89dceb", .image: "f5c2e7", .video: "f38ba8", .audio: "a6e3a1",
            .archive: "f9e2af", .document: "fab387", .data: "94e2d5", .model: "cba6f7",
            .model3d: "b4befe", .binary: "eba0ac", .system: "9399b2", .other: "7f849c",
        ], bg: "1e1e2e", ambient: 0.62)),
        // Nord — calm arctic blues, teals, muted aurora.
        Theme(id: "nord", name: "Nord", palette: .curated([
            .code: "81a1c1", .web: "88c0d0", .image: "b48ead", .video: "bf616a", .audio: "a3be8c",
            .archive: "ebcb8b", .document: "d08770", .data: "8fbcbb", .model: "c98fb5",
            .model3d: "5e81ac", .binary: "d8a07a", .system: "6b7488", .other: "7b8394",
        ], bg: "2e3440", ambient: 0.58)),
        // Solarized — the iconic teal-dark canvas with warm accents.
        Theme(id: "solarized", name: "Solarized", palette: .curated([
            .code: "268bd2", .web: "2aa198", .image: "d33682", .video: "dc322f", .audio: "859900",
            .archive: "b58900", .document: "cb4b16", .data: "4bb3a5", .model: "c044a0",
            .model3d: "6c71c4", .binary: "d2691e", .system: "586e75", .other: "657b83",
        ], bg: "002b36", ambient: 0.55)),
        // Synthwave — neon on deep purple-black. Maximum fun.
        Theme(id: "synthwave", name: "Synthwave", palette: .curated([
            .code: "a679ff", .web: "36f9f6", .image: "ff7edb", .video: "ff3cab", .audio: "72f1b8",
            .archive: "fede5d", .document: "ff8b39", .data: "2de2e6", .model: "ff5fd2",
            .model3d: "7b6cff", .binary: "ff6f3c", .system: "6d5a9c", .other: "9d8bbf",
        ], bg: "1a0b2e", ambient: 0.55)),
        // Gruvbox — warm retro earth tones.
        Theme(id: "gruvbox", name: "Gruvbox", palette: .curated([
            .code: "83a598", .web: "8ec07c", .image: "d3869b", .video: "fb4934", .audio: "b8bb26",
            .archive: "fabd2f", .document: "fe8019", .data: "689d6a", .model: "e08ba0",
            .model3d: "7daeb8", .binary: "d65d0e", .system: "928374", .other: "a89984",
        ], bg: "282828", ambient: 0.58)),
        // Winter — cool icy jewels, high contrast.
        Theme(id: "winter", name: "Winter", palette: .curated([
            .code: "1f6feb", .web: "0f9d8a", .image: "d4214a", .video: "c01f7a", .audio: "13b05a", .archive: "e6d24a", .document: "e8eef5",
            .data: "1aa6c4", .model: "7b3fe4", .model3d: "5566d8", .binary: "e0476d", .system: "8893a6", .other: "b9c2d0",
        ], bg: "0c1420", ambient: 0.56)),
        // Spring — warm, bright, clear & light.
        Theme(id: "spring", name: "Spring", palette: .curated([
            .code: "ff7a52", .web: "2fc4bf", .image: "ffd24a", .video: "ff5d8f", .audio: "8fc63d", .archive: "f5a623", .document: "ffe0a0",
            .data: "7aa6f0", .model: "b06fd6", .model3d: "ff9a6b", .binary: "ff6f5e", .system: "b8a07a", .other: "d8c2a0",
        ], bg: "16100a", ambient: 0.60)),
        // Summer — cool, soft, dusty pastels.
        Theme(id: "summer", name: "Summer", palette: .curated([
            .code: "7f9ec2", .web: "6fb7b0", .image: "d59aa8", .video: "c07f96", .audio: "9ec3a8", .archive: "e3d2a8", .document: "cdd6e0",
            .data: "84a7c4", .model: "b49ec6", .model3d: "9a8fb8", .binary: "c79a8a", .system: "9aa3b0", .other: "b8bcc6",
        ], bg: "1b2330", ambient: 0.58)),
        // Autumn — warm, muted, earthy & golden.
        Theme(id: "autumn", name: "Autumn", palette: .curated([
            .code: "c9962e", .web: "1f7a6e", .image: "c0532a", .video: "8a2f3f", .audio: "7d7a35", .archive: "d2a02e", .document: "e0c79a",
            .data: "4f79a0", .model: "8a2f55", .model3d: "a8762e", .binary: "c4622a", .system: "8a7a5e", .other: "a8987a",
        ], bg: "170f0a", ambient: 0.52)),
        // Circus — bold vintage carnival.
        Theme(id: "circus", name: "Circus", palette: .curated([
            .code: "d6243a", .web: "1f7ab0", .image: "f2b21e", .video: "e2452f", .audio: "2e8f4f", .archive: "caa23a", .document: "ecdcb0",
            .data: "3a9bc4", .model: "c23a78", .model3d: "7a4fa0", .binary: "e67630", .system: "9a7a4a", .other: "c2a878",
        ], bg: "1a1008", ambient: 0.56)),
        // Pop Synth — neon synthwave pop.
        Theme(id: "popsynth", name: "Pop Synth", palette: .curated([
            .code: "ff4fd8", .web: "36f9f6", .image: "ff5fa2", .video: "ff2e97", .audio: "5cffb1", .archive: "ffe14d", .document: "d6a8ff",
            .data: "2de2e6", .model: "b06bff", .model3d: "7b6cff", .binary: "ff8b39", .system: "6d5a9c", .other: "9d8bbf",
        ], bg: "160a2e", ambient: 0.55)),
        // Candy — bright playful sweets.
        Theme(id: "candy", name: "Candy", palette: .curated([
            .code: "ff5d8f", .web: "3bc9db", .image: "ff9a3c", .video: "ff4d6d", .audio: "7bd957", .archive: "ffd23f", .document: "ffe6f0",
            .data: "4dc9ff", .model: "ff6fd0", .model3d: "9b7bff", .binary: "ff7a45", .system: "c0a8cc", .other: "d8c4d8",
        ], bg: "1a1220", ambient: 0.60)),
        // Forest — deep woodland greens & bark.
        Theme(id: "forest", name: "Forest", palette: .curated([
            .code: "5fae6a", .web: "3f9d8a", .image: "c7a13a", .video: "b5532e", .audio: "8fbf4d", .archive: "caa24a", .document: "d8c79a",
            .data: "4f9a7a", .model: "a06a3a", .model3d: "6b8e3a", .binary: "c07a3a", .system: "6a7355", .other: "8a8a6a",
        ], bg: "0e160e", ambient: 0.50)),
        // Ocean — deep sea blues, coral biolum.
        Theme(id: "ocean", name: "Ocean", palette: .curated([
            .code: "2f9bd0", .web: "1fb0a8", .image: "ff7e6b", .video: "ef5a78", .audio: "4fd0c0", .archive: "e0b65a", .document: "bfe0e6",
            .data: "3f8fd0", .model: "7a6fd8", .model3d: "2f6f9e", .binary: "ef8f5a", .system: "5a7585", .other: "7e96a0",
        ], bg: "08141c", ambient: 0.50)),
        // Sunset — warm gold to magenta dusk.
        Theme(id: "sunset", name: "Sunset", palette: .curated([
            .code: "ff8c42", .web: "ff6f91", .image: "ffd166", .video: "e63950", .audio: "ff9e6d", .archive: "f2b134", .document: "ffd9bf",
            .data: "ff5d73", .model: "c44fb0", .model3d: "8a5fc0", .binary: "ff7a45", .system: "9c6f7a", .other: "c2929a",
        ], bg: "1e0f18", ambient: 0.56)),
        // Ember — black, red, orange, glow.
        Theme(id: "ember", name: "Ember", palette: .curated([
            .code: "ff6a2e", .web: "e03a2e", .image: "ffb23f", .video: "ff3b2e", .audio: "ff8f3a", .archive: "d98a2e", .document: "f2c79a",
            .data: "ff5a45", .model: "c43a4a", .model3d: "9e4a3a", .binary: "ff7e2e", .system: "6e4a40", .other: "8a6a5a",
        ], bg: "160806", ambient: 0.50)),
        // Jewel — emerald, ruby, sapphire, topaz.
        Theme(id: "jewel", name: "Jewel", palette: .curated([
            .code: "2f7ad0", .web: "1aa57a", .image: "d63a6a", .video: "c4263f", .audio: "2faa8a", .archive: "e0a82e", .document: "cbb7e6",
            .data: "3f8fd0", .model: "8a3fc0", .model3d: "5a4fc0", .binary: "d97a2e", .system: "5a6075", .other: "7e8296",
        ], bg: "0b0c12", ambient: 0.55)),
    ]
    static var `default`: Theme { presets[0] }
}

/// Live, persisted custom-theme parameters. Global OKLCH knobs (chroma scale + lightness
/// shift, applied to every category's base) plus per-category L/C/H overrides that win over
/// the global transform, plus cushion ambient and an OKLCH-derived background. Editing any of
/// these bumps `paletteRevision` so the views re-tint live (Live-Wire feel).
struct CustomThemeParams: Equatable {
    var chroma: Double = 1.0       // multiplier on each category's base chroma
    var lightness: Double = 0.0    // additive shift on each base lightness
    var ambient: Double = 0.58     // cushion ambient floor
    var bgL: Double = 0.05         // background OKLCH lightness
    var bgChroma: Double = 0.015   // subtle background tint chroma
    var bgHue: Double = 250        // background tint hue
    /// Explicit per-category overrides (L,C,H) — empty unless the user hand-tunes a category.
    var overrides: [FilePalette.Category: FilePalette.OKLCH] = [:]

    /// Build the live palette: global transform, then explicit overrides, then bg + ambient.
    var palette: ThemePalette {
        var o: [FilePalette.Category: FilePalette.OKLCH] = [:]
        for cat in FilePalette.Category.allCases {
            if let ov = overrides[cat] { o[cat] = ov; continue }
            let b = FilePalette.oklch(cat)
            o[cat] = FilePalette.OKLCH(min(1, max(0, b.L + lightness)), max(0, b.C * chroma), b.H)
        }
        let bg = FilePalette.srgb(FilePalette.OKLCH(bgL, bgChroma, bgHue))
        return ThemePalette(overrides: o, ambient: ambient, background: (bg.r, bg.g, bg.b))
    }
}

/// Persisted theme selection + live custom-theme parameters.
final class ThemeManager: ObservableObject {
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "diskscope.theme"); paletteRevision += 1 }
    }
    @Published var custom: CustomThemeParams {
        didSet { persistCustom(); paletteRevision += 1 }
    }
    /// Bumped on any change that affects the active palette — the views watch this to re-tint.
    @Published private(set) var paletteRevision = 0

    init() {
        selectedID = UserDefaults.standard.string(forKey: "diskscope.theme") ?? Theme.default.id
        custom = ThemeManager.loadCustom()
    }

    var isCustom: Bool { selectedID == Theme.customID }

    var current: Theme {
        if isCustom { return Theme(id: Theme.customID, name: "Custom", palette: custom.palette) }
        return Theme.presets.first { $0.id == selectedID } ?? Theme.default
    }

    /// Switch to the custom theme, seeding its global knobs from the named preset so the user
    /// starts from "this preset, now editable" rather than from scratch.
    func customize(from presetID: String) {
        let p = (Theme.presets.first { $0.id == presetID } ?? Theme.default).palette
        // Seed the custom theme with the preset's exact per-category colors (so the swatch grid
        // starts from "this theme, now editable"), plus its ambient + OKLCH-decomposed background.
        custom.overrides = p.overrides
        custom.ambient = p.ambient
        let bg = FilePalette.oklch(fromSRGB: p.background)
        custom.bgL = bg.L; custom.bgChroma = bg.C; custom.bgHue = bg.H
        custom.chroma = 1.0; custom.lightness = 0.0
        selectedID = Theme.customID
    }

    // MARK: - Custom persistence (JSON in UserDefaults)

    private struct Stored: Codable {
        var chroma, lightness, ambient, bgL, bgChroma, bgHue: Double
        var overrides: [String: [Double]] // category rawValue -> [L, C, H]
    }

    private func persistCustom() {
        let s = Stored(chroma: custom.chroma, lightness: custom.lightness, ambient: custom.ambient,
                       bgL: custom.bgL, bgChroma: custom.bgChroma, bgHue: custom.bgHue,
                       overrides: custom.overrides.reduce(into: [:]) { $0[$1.key.rawValue] = [$1.value.L, $1.value.C, $1.value.H] })
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: "diskscope.customTheme")
        }
    }

    private static func loadCustom() -> CustomThemeParams {
        guard let data = UserDefaults.standard.data(forKey: "diskscope.customTheme"),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return CustomThemeParams() }
        var p = CustomThemeParams(chroma: s.chroma, lightness: s.lightness, ambient: s.ambient,
                                  bgL: s.bgL, bgChroma: s.bgChroma, bgHue: s.bgHue)
        for (raw, lch) in s.overrides where lch.count == 3 {
            if let cat = FilePalette.Category(rawValue: raw) { p.overrides[cat] = FilePalette.OKLCH(lch[0], lch[1], lch[2]) }
        }
        return p
    }
}
