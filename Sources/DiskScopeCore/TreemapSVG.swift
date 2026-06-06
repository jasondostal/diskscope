import Foundation

/// Render a laid-out treemap to a standalone SVG string — a headless way to *see* the
/// treemap (and eyeball the layout for slivers/gaps) without the GUI app. The real app
/// will draw the same TreemapTiles via SwiftUI Canvas/Metal; this proves the pipeline.
public enum TreemapSVG {

    public static func render(tiles: [TreemapTile], index: FileIndex, canvas: Rect,
                              background: String = "#0b0d10") -> String {
        var s = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(canvas.w))" height="\(Int(canvas.h))" \
        viewBox="0 0 \(Int(canvas.w)) \(Int(canvas.h))">
        <rect width="100%" height="100%" fill="\(background)"/>

        """

        // Leaves (files) tile the whole canvas — the classic WinDirStat fill, colored by type.
        for t in tiles where !t.isDir {
            let name = index.nodes[t.node].name
            s += rect(t.rect, fill: FilePalette.hex(forExt: ext(of: name)), stroke: "#00000040", strokeW: 0.5)
        }
        // Outline top-level folders so the major structure reads through the file colors.
        for t in tiles where t.isDir && t.depth == 1 {
            s += rect(t.rect, fill: "none", stroke: "#ffffff66", strokeW: 1.2)
        }

        s += "</svg>\n"
        return s
    }

    private static func rect(_ r: Rect, fill: String, stroke: String, strokeW: Double) -> String {
        let x = fmt(r.x), y = fmt(r.y), w = fmt(max(0, r.w)), h = fmt(max(0, r.h))
        return "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(strokeW)\"/>\n"
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private static func ext(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Stable hue per extension → a vibrant, dark-friendly fill. (The real UI will use
    /// OKLCH for perceptual uniformity; HSL keeps this renderer dependency-free and
    /// universally drawable.)
    private static func color(forExtension e: String) -> String {
        guard !e.isEmpty else { return "hsl(220 8% 38%)" } // no-extension: muted gray-blue
        var h: UInt64 = 1469598103934665603 // FNV-1a for a stable spread
        for b in e.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let hue = Int(h % 360)
        return "hsl(\(hue) 65% 55%)"
    }
}
