import Foundation

public extension FilePalette {
    /// Optional "recency shading" — a composable LAYER over any theme. It drains saturation out
    /// of OLD files (toward grey of the same luminance, so the cushion's lightness shading is
    /// preserved) based on how long since each file was modified. It MODULATES the theme's colors;
    /// it never replaces them. Off by default. The same struct drives the app and the TUI.
    struct RecencyShading: Sendable, Equatable {
        public var enabled: Bool
        public var strength: Double     // 0…1 — how fully the oldest files desaturate
        public var horizonDays: Double  // files untouched this long read as fully "old"
        public init(enabled: Bool = false, strength: Double = 0.7, horizonDays: Double = 365) {
            self.enabled = enabled
            self.strength = min(1, max(0, strength))
            self.horizonDays = max(1, horizonDays)
        }

        /// 0 (modified now) … 1 (older than the horizon). 0 when modTime is unknown.
        public func age(modTime: Int64, now: Int64) -> Double {
            guard modTime > 0 else { return 0 }
            return min(1, max(0, Double(now - modTime) / (horizonDays * 86_400)))
        }

        /// Apply the layer to a base sRGB color (0…1) for a file with the given modTime. When
        /// disabled it's the identity, so callers can wrap every tile unconditionally.
        public func apply(_ base: (r: Double, g: Double, b: Double),
                          modTime: Int64, now: Int64) -> (r: Double, g: Double, b: Double) {
            guard enabled else { return base }
            let s = pow(max(0, 1 - age(modTime: modTime, now: now) * strength), 1.15)
            let g = 0.30 * base.r + 0.59 * base.g + 0.11 * base.b   // Rec.601 luminance
            return (base.r * s + g * (1 - s), base.g * s + g * (1 - s), base.b * s + g * (1 - s))
        }
    }
}
