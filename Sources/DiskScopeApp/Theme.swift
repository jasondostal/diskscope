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
}

struct Theme: Identifiable {
    let id: String
    let name: String
    let palette: ThemePalette

    static let customID = "custom"

    static let presets: [Theme] = [
        Theme(id: "nocturne", name: "Nocturne",
              palette: ThemePalette(overrides: [:], ambient: 0.58, background: (0.043, 0.051, 0.063))),
        Theme(id: "vivid", name: "Vivid",
              palette: .variant(chroma: 1.7, lightness: 0.02)),
        Theme(id: "slate", name: "Slate",
              palette: .variant(chroma: 0.3, lightness: 0.02, bg: (0.05, 0.055, 0.062))),
        Theme(id: "ember", name: "Ember",
              palette: .variant(chroma: 1.2, lightness: 0.0, bg: (0.07, 0.05, 0.045), ambient: 0.55)),
        Theme(id: "abyss", name: "Abyss",
              palette: .variant(chroma: 0.9, lightness: 0.0, bg: (0.02, 0.03, 0.05), ambient: 0.5)),
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
        switch presetID {
        case "vivid": custom.chroma = 1.7; custom.lightness = 0.02
        case "slate": custom.chroma = 0.3; custom.lightness = 0.02; custom.bgL = 0.055
        case "ember": custom.chroma = 1.2; custom.lightness = 0.0; custom.ambient = 0.55; custom.bgL = 0.06; custom.bgHue = 40
        case "abyss": custom.chroma = 0.9; custom.lightness = 0.0; custom.ambient = 0.5; custom.bgL = 0.03; custom.bgHue = 250
        default: break // nocturne ≈ defaults
        }
        custom.overrides = [:]
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
