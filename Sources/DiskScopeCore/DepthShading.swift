import Foundation

public extension FilePalette {
    /// Optional "depth shading" — a composable LAYER over any theme. It progressively mutes
    /// deeper-nested files (toward grey of the same luminance, so the cushion shading survives),
    /// so the top-level folder structure reads boldest and deep nesting recedes — the QDirStat
    /// trick of making hierarchy visible through desaturation. Modulates the theme; never replaces
    /// it. Off by default. Depth is measured from the currently-viewed root (0 = top of view).
    struct DepthShading: Sendable, Equatable {
        public var enabled: Bool
        public var strength: Double   // 0…1 — how fully the deepest levels desaturate
        public var fullDepth: Int     // depth at which the fade reaches its maximum
        public init(enabled: Bool = false, strength: Double = 0.6, fullDepth: Int = 8) {
            self.enabled = enabled
            self.strength = min(1, max(0, strength))
            self.fullDepth = max(1, fullDepth)
        }

        /// Apply the layer to a base sRGB color (0…1) for a tile at the given depth. Identity when
        /// disabled, so callers can wrap every tile unconditionally.
        public func apply(_ base: (r: Double, g: Double, b: Double), depth: Int) -> (r: Double, g: Double, b: Double) {
            guard enabled, depth > 0 else { return base }
            let d = min(1, Double(depth) / Double(fullDepth))
            let s = max(0, 1 - d * strength)
            let g = 0.30 * base.r + 0.59 * base.g + 0.11 * base.b   // Rec.601 luminance
            return (base.r * s + g * (1 - s), base.g * s + g * (1 - s), base.b * s + g * (1 - s))
        }
    }
}
