import SwiftUI
import DiskScopeCore

/// SwiftUI-facing wrapper over a Core `FilePalette.Palette`: per-category OKLCH overrides
/// (falling back to FilePalette's defaults), the cushion ambient floor, and the canvas
/// background. All app color lookups route through the model's current palette, so switching
/// themes retints the treemap, legend, and tree. The actual theme DATA lives in DiskScopeCore
/// (`FilePalette.themePresets`) so the app and the terminal UI ship identical themes.
struct ThemePalette {
    var overrides: [FilePalette.Category: FilePalette.OKLCH]
    var ambient: Double
    var background: (r: Double, g: Double, b: Double)

    init(overrides: [FilePalette.Category: FilePalette.OKLCH], ambient: Double,
         background: (r: Double, g: Double, b: Double)) {
        self.overrides = overrides; self.ambient = ambient; self.background = background
    }
    /// Wrap a Core palette (the shared, UI-free theme data) for SwiftUI use.
    init(_ core: FilePalette.Palette) {
        self.overrides = core.overrides; self.ambient = core.ambient; self.background = core.background
    }

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
}

struct Theme: Identifiable {
    let id: String
    let name: String
    let palette: ThemePalette

    static let customID = "custom"

    /// Derived from the shared Core library (`FilePalette.themePresets`) so the app's picker and
    /// the TUI's `--theme` flag offer the exact same themes.
    static let presets: [Theme] = FilePalette.themePresets.map {
        Theme(id: $0.id, name: $0.name, palette: ThemePalette($0.palette))
    }
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
    /// Optional recency-shading LAYER — drains color from old files. Composes over any theme;
    /// off by default. Bumps paletteRevision so the treemap re-renders live.
    @Published var recency: FilePalette.RecencyShading {
        didSet { persistRecency(); paletteRevision += 1 }
    }
    /// Optional depth-shading LAYER — mutes deeper-nested files so structure reads. Off by default.
    @Published var depth: FilePalette.DepthShading {
        didSet { persistDepth(); paletteRevision += 1 }
    }
    /// Bumped on any change that affects the active palette — the views watch this to re-tint.
    @Published private(set) var paletteRevision = 0

    init() {
        selectedID = UserDefaults.standard.string(forKey: "diskscope.theme") ?? Theme.default.id
        custom = ThemeManager.loadCustom()
        recency = ThemeManager.loadRecency()
        depth = ThemeManager.loadDepth()
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

    // MARK: - Recency-shading persistence

    private func persistRecency() {
        let d = UserDefaults.standard
        d.set(recency.enabled, forKey: "diskscope.recency.enabled")
        d.set(recency.strength, forKey: "diskscope.recency.strength")
        d.set(recency.horizonDays, forKey: "diskscope.recency.horizonDays")
    }

    private static func loadRecency() -> FilePalette.RecencyShading {
        let d = UserDefaults.standard
        guard d.object(forKey: "diskscope.recency.enabled") != nil else { return FilePalette.RecencyShading() }
        return FilePalette.RecencyShading(enabled: d.bool(forKey: "diskscope.recency.enabled"),
                                          strength: d.double(forKey: "diskscope.recency.strength"),
                                          horizonDays: d.double(forKey: "diskscope.recency.horizonDays"))
    }

    // MARK: - Depth-shading persistence

    private func persistDepth() {
        let d = UserDefaults.standard
        d.set(depth.enabled, forKey: "diskscope.depth.enabled")
        d.set(depth.strength, forKey: "diskscope.depth.strength")
        d.set(depth.fullDepth, forKey: "diskscope.depth.fullDepth")
    }

    private static func loadDepth() -> FilePalette.DepthShading {
        let d = UserDefaults.standard
        guard d.object(forKey: "diskscope.depth.enabled") != nil else { return FilePalette.DepthShading() }
        return FilePalette.DepthShading(enabled: d.bool(forKey: "diskscope.depth.enabled"),
                                        strength: d.double(forKey: "diskscope.depth.strength"),
                                        fullDepth: d.integer(forKey: "diskscope.depth.fullDepth"))
    }
}
