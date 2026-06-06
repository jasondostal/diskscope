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

/// Persisted theme selection.
final class ThemeManager: ObservableObject {
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "diskscope.theme") }
    }
    init() { selectedID = UserDefaults.standard.string(forKey: "diskscope.theme") ?? Theme.default.id }
    var current: Theme { Theme.presets.first { $0.id == selectedID } ?? Theme.default }
}
