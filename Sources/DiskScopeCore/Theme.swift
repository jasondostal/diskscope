import Foundation

/// Theme data lives in Core (not the SwiftUI app) so BOTH the interactive app and the terminal
/// UI render identical themes from one source of truth. A `Palette` is per-category OKLCH
/// overrides (falling back to FilePalette's base colors) plus the cushion ambient floor and the
/// canvas background — all free of any UI framework. The app wraps this with SwiftUI `Color`
/// conveniences; the TUI consumes the sRGB tuples directly.
public extension FilePalette {

    struct Palette: Sendable {
        public var overrides: [Category: OKLCH]
        public var ambient: Double
        public var background: (r: Double, g: Double, b: Double)
        public init(overrides: [Category: OKLCH], ambient: Double, background: (r: Double, g: Double, b: Double)) {
            self.overrides = overrides; self.ambient = ambient; self.background = background
        }

        public func oklch(_ cat: Category) -> OKLCH { overrides[cat] ?? FilePalette.oklch(cat) }
        public func oklch(forExt e: String) -> OKLCH {
            overrides[FilePalette.category(forExt: e)] ?? FilePalette.oklch(forExt: e)
        }
        public func srgb(_ cat: Category) -> (r: Double, g: Double, b: Double) { FilePalette.srgb(oklch(cat)) }
        public func srgb(forExt e: String) -> (r: Double, g: Double, b: Double) { FilePalette.srgb(oklch(forExt: e)) }

        /// Build a fully-specified palette from a curated hex scheme: each category maps to its own
        /// hex (through the OKLCH pipeline), plus a background hex. This is how themes get GENUINELY
        /// different hue families rather than the same hues at different brightness.
        public static func curated(_ map: [Category: String], bg: String, ambient: Double) -> Palette {
            var o: [Category: OKLCH] = [:]
            for cat in Category.allCases where map[cat] != nil { o[cat] = FilePalette.oklch(hex: map[cat]!) }
            return Palette(overrides: o, ambient: ambient, background: FilePalette.srgb(hex: bg))
        }
    }

    struct Theme: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let palette: Palette
        public init(id: String, name: String, palette: Palette) {
            self.id = id; self.name = name; self.palette = palette
        }
    }

    /// Look up a shipped theme by id (e.g. "winter", "halloween"). nil if unknown.
    static func theme(id: String) -> Theme? { themePresets.first { $0.id == id } }

    /// The shipped theme library — single source of truth for the app's picker and the TUI's
    /// `--theme` flag. A theme's identity comes from coherence across temperature × value × chroma,
    /// not from spreading category hues across the whole wheel.
    static let themePresets: [Theme] = [
        // Spectrum — vivid even-spaced base (empty overrides use FilePalette's own colors).
        Theme(id: "spectrum", name: "Spectrum",
              palette: Palette(overrides: [:], ambient: 0.58, background: FilePalette.srgb(hex: "0b0d10"))),
        // Cairn — near-black canvas with Cairn's "memory jellybean" colors.
        Theme(id: "cairn", name: "Cairn", palette: .curated([
            .code: "4d9bff", .web: "2ed9c4", .image: "ff5d8f", .video: "ff4d6d", .audio: "2ed99a",
            .archive: "efa83a", .document: "b06bff", .data: "5ab0ff", .model: "d24dff",
            .model3d: "7c6bff", .binary: "ff8a3d", .system: "6b7280", .other: "8a8f9c",
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
        // Synthwave — neon on deep purple-black.
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
        // Halloween — pumpkin, witch-purple, toxic green.
        Theme(id: "halloween", name: "Halloween", palette: .curated([
            .code: "ff7518", .web: "6cbf2e", .image: "b026ff", .video: "c01622", .audio: "76b900", .archive: "ff9e1b", .document: "e8d8b0",
            .data: "8a3ffb", .model: "ff5c00", .model3d: "6a2fb0", .binary: "d2421f", .system: "4a4458", .other: "6b6478",
        ], bg: "0c0810", ambient: 0.50)),
        // Christmas — red, pine green, gold & snow.
        Theme(id: "christmas", name: "Christmas", palette: .curated([
            .code: "1f8a4c", .web: "2faa6a", .image: "d1232a", .video: "b01722", .audio: "2e9d55", .archive: "e0b740", .document: "f0ead6",
            .data: "3aa0a0", .model: "c0392b", .model3d: "1f6e3a", .binary: "d98c2b", .system: "7a8a7a", .other: "b8c2b0",
        ], bg: "0c1410", ambient: 0.54)),
        // Horror — dried blood, sickly green, bone.
        Theme(id: "horror", name: "Horror", palette: .curated([
            .code: "6e7d5a", .web: "4a6a5a", .image: "8a1f22", .video: "b01015", .audio: "5a6e3a", .archive: "8a7a4a", .document: "cabfa0",
            .data: "3a4a5a", .model: "5a2f4a", .model3d: "3a2f3a", .binary: "7a3a2a", .system: "3a3a3e", .other: "5a565a",
        ], bg: "08080a", ambient: 0.42)),
        // Vaporwave — pastel cyan, hot pink, lavender.
        Theme(id: "vaporwave", name: "Vaporwave", palette: .curated([
            .code: "6ad7ff", .web: "2bd9d2", .image: "ff6ec7", .video: "ff8fb0", .audio: "9d7bff", .archive: "ffd6a0", .document: "efe0ff",
            .data: "7ad0ff", .model: "ff8fe0", .model3d: "b08fff", .binary: "ffae8f", .system: "9aa0c8", .other: "c4bfe0",
        ], bg: "18102a", ambient: 0.58)),
        // Harvest — '70s avocado, gold, burnt orange.
        Theme(id: "harvest", name: "Harvest", palette: .curated([
            .code: "6b8e23", .web: "5a7d3a", .image: "d98a2b", .video: "b5532e", .audio: "8a9a2a", .archive: "e0a52e", .document: "e8d2a0",
            .data: "c08a3a", .model: "9a4a2a", .model3d: "6e5a2a", .binary: "c4632a", .system: "7a6a4a", .other: "9a8a6a",
        ], bg: "161009", ambient: 0.52)),
        // Sakura — cherry blossom pink, petal, leaf.
        Theme(id: "sakura", name: "Sakura", palette: .curated([
            .code: "ff8fb0", .web: "6fc2a0", .image: "ffb7c8", .video: "ff6f91", .audio: "9ed47a", .archive: "f5d76e", .document: "fdeef0",
            .data: "8fb8e0", .model: "d98fc8", .model3d: "b08fd0", .binary: "ff9e7a", .system: "b8a8b0", .other: "d8c8cc",
        ], bg: "1a1014", ambient: 0.60)),
        // Matrix — phosphor green on black.
        Theme(id: "matrix", name: "Matrix", palette: .curated([
            .code: "00ff66", .web: "2ee88a", .image: "66ff99", .video: "00cc52", .audio: "88ff88", .archive: "aaff66", .document: "ccffcc",
            .data: "00e676", .model: "33ffaa", .model3d: "00b34a", .binary: "7fff00", .system: "2a5a3a", .other: "4a6a4a",
        ], bg: "020806", ambient: 0.45)),
        // Noir — greyscale film, warm accents.
        Theme(id: "noir", name: "Noir", palette: .curated([
            .code: "c8c8c8", .web: "a8a8a8", .image: "d84a3a", .video: "b83a2a", .audio: "989898", .archive: "d2a24a", .document: "e8e8e8",
            .data: "888888", .model: "b85a4a", .model3d: "787878", .binary: "c87a3a", .system: "585858", .other: "686868",
        ], bg: "0a0a0b", ambient: 0.48)),
        // Tropical — turquoise, hibiscus, mango, lime.
        Theme(id: "tropical", name: "Tropical", palette: .curated([
            .code: "16c4b0", .web: "00b4a0", .image: "ff5e8a", .video: "ff7a3d", .audio: "7ad13a", .archive: "ffd23f", .document: "fff0c8",
            .data: "2eb8e0", .model: "ff5fb0", .model3d: "a06fd0", .binary: "ff8a3d", .system: "7a9a8a", .other: "a8c2a8",
        ], bg: "07201e", ambient: 0.56)),
    ]
}
