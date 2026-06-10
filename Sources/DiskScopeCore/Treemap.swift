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
    /// Directory tiles whose children were (partly or fully) too small to emit must paint
    /// as a backdrop cushion themselves — otherwise their region renders as a background
    /// hole (the classic "folder of 100k tiny files shows as a black void").
    public var renderBackdrop = false
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
        let myTile = tiles.count
        let isDir = index.nodes[node].isDir
        tiles.append(TreemapTile(node: node, rect: rect, depth: depth, isDir: isDir, cushion: c))
        guard depth < maxDepth, isDir, rect.w >= minSide, rect.h >= minSide else {
            // A directory we won't subdivide (depth cap) still owns visible area.
            if isDir { tiles[myTile].renderBackdrop = true }
            return
        }

        // Children that occupy space, largest first (squarify wants descending sizes).
        let kids = index.children(of: node)
            .map { (node: $0, size: Double(index.nodes[$0].totalSize)) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        guard !kids.isEmpty else { return }

        var emitted = 0
        for (childNode, childRect) in squarify(kids, in: rect) where childRect.w >= minSide && childRect.h >= minSide {
            layoutNode(index, node: childNode, rect: childRect, depth: depth + 1,
                       maxDepth: maxDepth, minSide: minSide,
                       coeffs: c, h: h * scale, scale: scale, into: &tiles)
            emitted += 1
        }
        // Any child below minSide was skipped — paint this dir as the backdrop under the
        // gap. (Tiles are parent-before-child, so the backdrop renders first.)
        if emitted < kids.count { tiles[myTile].renderBackdrop = true }
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

    /// Precomputed linear-light → sRGB byte table (per-pixel pow() would dominate the loop).
    private static let srgbLUT: [UInt8] = (0..<4096).map { i in
        let v = Double(i) / 4095
        let s = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    private static func toLinear(_ v: Double) -> Double {
        let c = max(0, min(1, v))
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Render cushioned, Phong-shaded cells into an RGBA8 pixel buffer (width*height*4,
    /// premultiplied-opaque). No CoreGraphics dependency — pure bytes — so it's testable and
    /// the caller wraps it in a CGImage. `colorFor` is handed the whole tile (node, depth,
    /// rect) and returns its base sRGB (0…1); it's also called for backdrop DIRECTORY tiles
    /// (check `tile.isDir`), which paint as flatter pillows under regions whose files were
    /// too small to emit.
    ///
    /// Shading happens in linear light (diffuse + a small Blinn-Phong specular), mapped back
    /// to sRGB through a LUT; `ambient` keeps its tuned gamma-space meaning (it's converted
    /// internally), so existing themes look the same at the floor and crisper in the slopes.
    /// The pixel fill parallelizes across row bands — it's the GUI's whole-canvas cost.
    public static func renderCushionRGBA(
        tiles: [TreemapTile], width: Int, height: Int,
        background: (r: Double, g: Double, b: Double) = (0.043, 0.051, 0.063),
        light: (x: Double, y: Double, z: Double) = (-0.32, -0.45, 0.83),
        ambient: Double = 0.42,
        cushionHeight: Double = 0.6,
        specular: Double = 0.13,
        colorFor: (TreemapTile) -> (r: Double, g: Double, b: Double)
    ) -> [UInt8] {
        var buf = [UInt8](repeating: 255, count: max(0, width * height * 4))
        guard width > 0, height > 0 else { return buf }

        // Resolve paint order + colors up front: leaves plus backdrop dirs, parent-first
        // (so backdrops underlay their children), colors linearized once per tile —
        // colorFor hashes strings and must stay out of the pixel loop.
        struct Paint {
            let x0, y0, x1, y1: Int
            let s1x, s2x, s1y, s2y: Double
            let r, g, b: Double // linear
        }
        var paints: [Paint] = []
        paints.reserveCapacity(tiles.count)
        for t in tiles where !t.isDir || t.renderBackdrop {
            let rx = t.rect.x, ry = t.rect.y, rw = t.rect.w, rh = t.rect.h
            guard rw > 0, rh > 0 else { continue }
            let x0 = max(0, Int(rx.rounded(.down)))
            let y0 = max(0, Int(ry.rounded(.down)))
            let x1 = min(width, Int((rx + rw).rounded(.up)))
            let y1 = min(height, Int((ry + rh).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            // A FRESH cushion per cell, in the cell's own coordinates — a clean parabolic
            // pillow peaking dead-center, identical in shape from tile to tile (the
            // KDirStat/QDirStat look). Backdrop dirs get a flatter pillow so they read as
            // "ground" under their children.
            let h = t.isDir ? cushionHeight * 0.5 : cushionHeight
            let c = colorFor(t)
            paints.append(Paint(
                x0: x0, y0: y0, x1: x1, y1: y1,
                s1x: 4 * h * (2 * rx + rw) / rw, s2x: -4 * h / rw,
                s1y: 4 * h * (2 * ry + rh) / rh, s2y: -4 * h / rh,
                r: toLinear(c.r), g: toLinear(c.g), b: toLinear(c.b)))
        }

        let ll = (light.x * light.x + light.y * light.y + light.z * light.z).squareRoot()
        let lx = light.x / ll, ly = light.y / ll, lz = light.z / ll
        // Blinn-Phong halfway vector for the specular (viewer straight on: V = (0,0,1)).
        let hl = (lx * lx + ly * ly + (lz + 1) * (lz + 1)).squareRoot()
        let hx = lx / hl, hy = ly / hl, hz = (lz + 1) / hl
        // Themes tuned their ambient against gamma-space multiply; pow-map it so the
        // shadow floor matches while the gradient in between becomes physically smooth.
        let ambientLin = pow(max(0, min(1, ambient)), 2.2)

        let bgLin = (r: toLinear(background.r), g: toLinear(background.g), b: toLinear(background.b))
        let bgR = srgbLUT[Int(bgLin.r * 4095)], bgG = srgbLUT[Int(bgLin.g * 4095)], bgB = srgbLUT[Int(bgLin.b * 4095)]

        let lut = srgbLUT
        let bandH = 64
        let bands = (height + bandH - 1) / bandH
        buf.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let by0 = band * bandH
                let by1 = min(height, by0 + bandH)
                // Background for this band.
                for p in (by0 * width)..<(by1 * width) {
                    base[p * 4] = bgR; base[p * 4 + 1] = bgG; base[p * 4 + 2] = bgB
                }
                for t in paints {
                    let y0 = max(t.y0, by0), y1 = min(t.y1, by1)
                    guard y1 > y0 else { continue }
                    for py in y0..<y1 {
                        let fy = Double(py) + 0.5
                        let ny = -(2 * t.s2y * fy + t.s1y)
                        let rowBase = py * width
                        for px in t.x0..<t.x1 {
                            let fx = Double(px) + 0.5
                            let nx = -(2 * t.s2x * fx + t.s1x)
                            let nlen = (nx * nx + ny * ny + 1).squareRoot()
                            var cosA = (nx * lx + ny * ly + lz) / nlen
                            if cosA < 0 { cosA = 0 }
                            let intensity = min(1.0, ambientLin + (1 - ambientLin) * cosA)
                            // Specular: cos^16 via four squarings.
                            var spec = 0.0
                            if specular > 0 {
                                var ch = (nx * hx + ny * hy + hz) / nlen
                                if ch < 0 { ch = 0 }
                                ch *= ch; ch *= ch; ch *= ch; ch *= ch
                                spec = specular * ch
                            }
                            let i = (rowBase + px) * 4
                            base[i]     = lut[min(4095, Int((t.r * intensity + spec) * 4095))]
                            base[i + 1] = lut[min(4095, Int((t.g * intensity + spec) * 4095))]
                            base[i + 2] = lut[min(4095, Int((t.b * intensity + spec) * 4095))]
                        }
                    }
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
