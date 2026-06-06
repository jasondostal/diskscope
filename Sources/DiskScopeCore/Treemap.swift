import Foundation

/// A plain rectangle (no CoreGraphics dependency, so the layout is testable headless).
public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var area: Double { w * h }
}

/// Accumulated cushion-surface coefficients (van Wijk cushion treemaps). The surface
/// height adds a parabolic ridge per nesting level; these are the per-axis coefficients
/// so the renderer can derive the normal at any pixel: nx = -(2·s2x·x + s1x), ny likewise.
public struct Cushion: Sendable, Equatable {
    public var s1x = 0.0, s2x = 0.0, s1y = 0.0, s2y = 0.0
}

/// One laid-out cell: which index node it is, where it goes, how deep, whether it's a
/// directory (container) or file (leaf), and its accumulated cushion coefficients.
public struct TreemapTile: Sendable {
    public let node: Int
    public let rect: Rect
    public let depth: Int
    public let isDir: Bool
    public var cushion = Cushion()
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk 2000): subdivide a rectangle
/// among children in proportion to subtree size, choosing row orientation to keep cell
/// aspect ratios near 1 (square-ish cells read far better than thin slivers). Recurses
/// into directories until a cell is too small to be worth drawing.
///
/// Input is the aggregated FileIndex — call `index.aggregate()` first so `totalSize` is
/// populated. This is the WinDirStat view: every file a rectangle sized by bytes.
public enum Treemap {

    /// Lay out the subtree rooted at `root` inside `rect`.
    /// - minSide: stop recursing/emitting once a cell is smaller than this on a side
    ///   (in the same units as `rect` — typically pixels). Bounds the tile count on huge
    ///   trees: a 1px-floor over a screen-sized rect can't produce millions of tiles.
    public static func layout(_ index: FileIndex, root: Int, in rect: Rect,
                              maxDepth: Int = .max, minSide: Double = 1.0,
                              cushionHeight: Double = 0.5, cushionScale: Double = 0.75) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        layoutNode(index, node: root, rect: rect, depth: 0,
                   maxDepth: maxDepth, minSide: minSide,
                   coeffs: Cushion(), h: cushionHeight, scale: cushionScale, into: &tiles)
        return tiles
    }

    private static func layoutNode(_ index: FileIndex, node: Int, rect: Rect, depth: Int,
                                   maxDepth: Int, minSide: Double,
                                   coeffs: Cushion, h: Double, scale: Double,
                                   into tiles: inout [TreemapTile]) {
        // Add this rectangle's ridge to the inherited cushion (sharper as we go deeper).
        var c = coeffs
        addRidge(rect.x, rect.x + rect.w, h, &c.s1x, &c.s2x)
        addRidge(rect.y, rect.y + rect.h, h, &c.s1y, &c.s2y)
        tiles.append(TreemapTile(node: node, rect: rect, depth: depth,
                                 isDir: index.nodes[node].isDir, cushion: c))
        guard depth < maxDepth, index.nodes[node].isDir,
              rect.w >= minSide, rect.h >= minSide else { return }

        // Children that occupy space, largest first (squarify wants descending sizes).
        let kids = index.children(of: node)
            .map { (node: $0, size: Double(index.nodes[$0].totalSize)) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        guard !kids.isEmpty else { return }

        for (childNode, childRect) in squarify(kids, in: rect) where childRect.w >= minSide && childRect.h >= minSide {
            layoutNode(index, node: childNode, rect: childRect, depth: depth + 1,
                       maxDepth: maxDepth, minSide: minSide,
                       coeffs: c, h: h * scale, scale: scale, into: &tiles)
        }
    }

    /// Add a parabolic ridge over [x1,x2] (peaks at the centre, zero slope there; ±slope
    /// at the edges) into the cushion's per-axis coefficients.
    private static func addRidge(_ x1: Double, _ x2: Double, _ h: Double,
                                 _ s1: inout Double, _ s2: inout Double) {
        let w = x2 - x1
        guard w > 0 else { return }
        s1 += 4 * h * (x2 + x1) / w
        s2 -= 4 * h / w
    }

    /// Render cushioned, Phong-shaded leaf cells into an RGBA8 pixel buffer (width*height*4,
    /// premultiplied-opaque). No CoreGraphics dependency — pure bytes — so it's testable and
    /// the caller wraps it in a CGImage. `colorFor` returns the leaf's base sRGB (0…1).
    public static func renderCushionRGBA(
        tiles: [TreemapTile], width: Int, height: Int,
        background: (r: Double, g: Double, b: Double) = (0.043, 0.051, 0.063),
        light: (x: Double, y: Double, z: Double) = (-0.32, -0.45, 0.83),
        ambient: Double = 0.42,
        colorFor: (Int) -> (r: Double, g: Double, b: Double)
    ) -> [UInt8] {
        var buf = [UInt8](repeating: 255, count: max(0, width * height * 4))
        guard width > 0, height > 0 else { return buf }

        func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let bgR = u8(background.r), bgG = u8(background.g), bgB = u8(background.b)
        for p in 0..<(width * height) {
            buf[p * 4] = bgR; buf[p * 4 + 1] = bgG; buf[p * 4 + 2] = bgB
        }

        let ll = (light.x * light.x + light.y * light.y + light.z * light.z).squareRoot()
        let lx = light.x / ll, ly = light.y / ll, lz = light.z / ll

        for t in tiles where !t.isDir {
            let (cr, cg, cb) = colorFor(t.node)
            let c = t.cushion
            let x0 = max(0, Int(t.rect.x.rounded(.down)))
            let y0 = max(0, Int(t.rect.y.rounded(.down)))
            let x1 = min(width, Int((t.rect.x + t.rect.w).rounded(.up)))
            let y1 = min(height, Int((t.rect.y + t.rect.h).rounded(.up)))
            if x1 <= x0 || y1 <= y0 { continue }

            for py in y0..<y1 {
                let fy = Double(py) + 0.5
                let ny = -(2 * c.s2y * fy + c.s1y)
                let rowBase = py * width
                for px in x0..<x1 {
                    let fx = Double(px) + 0.5
                    let nx = -(2 * c.s2x * fx + c.s1x)
                    let nlen = (nx * nx + ny * ny + 1).squareRoot()
                    var cosA = (nx * lx + ny * ly + lz) / nlen
                    if cosA < 0 { cosA = 0 }
                    let intensity = min(1.0, ambient + (1 - ambient) * cosA)
                    let i = (rowBase + px) * 4
                    buf[i] = u8(cr * intensity)
                    buf[i + 1] = u8(cg * intensity)
                    buf[i + 2] = u8(cb * intensity)
                }
            }
        }
        return buf
    }

    /// Place size-weighted items into `rect`, keeping cells as square as possible.
    public static func squarify(_ items: [(node: Int, size: Double)], in rect: Rect) -> [(node: Int, rect: Rect)] {
        let total = items.reduce(0.0) { $0 + $1.size }
        guard total > 0, rect.area > 0 else { return [] }

        // Scale sizes to areas that exactly fill the rectangle.
        let scale = rect.area / total
        let areas = items.map { (node: $0.node, area: $0.size * scale) }

        var result: [(node: Int, rect: Rect)] = []
        var free = rect
        var row: [(node: Int, area: Double)] = []
        var i = 0
        while i < areas.count {
            let side = min(free.w, free.h)
            if row.isEmpty || worstRatio(row + [areas[i]], side) <= worstRatio(row, side) {
                row.append(areas[i]); i += 1
            } else {
                layoutRow(row, into: &result, free: &free); row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { layoutRow(row, into: &result, free: &free) }
        return result
    }

    /// Worst (largest) aspect ratio in a row laid along a side of length `side`.
    /// Lower is better; we keep adding to a row while this doesn't get worse.
    private static func worstRatio(_ row: [(node: Int, area: Double)], _ side: Double) -> Double {
        guard side > 0, !row.isEmpty else { return .infinity }
        var sum = 0.0, mn = Double.infinity, mx = 0.0
        for it in row { sum += it.area; mn = min(mn, it.area); mx = max(mx, it.area) }
        guard sum > 0, mn > 0 else { return .infinity }
        let s2 = sum * sum, side2 = side * side
        return max(side2 * mx / s2, s2 / (side2 * mn))
    }

    /// Lay a finished row as a strip along the shorter side, then shrink the free rect.
    private static func layoutRow(_ row: [(node: Int, area: Double)],
                                  into result: inout [(node: Int, rect: Rect)], free: inout Rect) {
        let sum = row.reduce(0.0) { $0 + $1.area }
        guard sum > 0 else { return }

        if free.w >= free.h {
            // Column on the left; its width is the row's total area / column height.
            let colW = sum / free.h
            var y = free.y
            for it in row {
                let h = colW > 0 ? it.area / colW : 0
                result.append((it.node, Rect(x: free.x, y: y, w: colW, h: h)))
                y += h
            }
            free = Rect(x: free.x + colW, y: free.y, w: max(0, free.w - colW), h: free.h)
        } else {
            // Strip across the top; its height is the row's total area / strip width.
            let rowH = sum / free.w
            var x = free.x
            for it in row {
                let w = rowH > 0 ? it.area / rowH : 0
                result.append((it.node, Rect(x: x, y: free.y, w: w, h: rowH)))
                x += w
            }
            free = Rect(x: free.x, y: free.y + rowH, w: free.w, h: max(0, free.h - rowH))
        }
    }
}
