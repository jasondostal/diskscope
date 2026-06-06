import Foundation

/// A plain rectangle (no CoreGraphics dependency, so the layout is testable headless).
public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var area: Double { w * h }
}

/// One laid-out cell: which index node it is, where it goes, how deep, and whether it's
/// a directory (container) or a file (leaf). The renderer colors leaves by type and may
/// draw directory borders/cushions.
public struct TreemapTile: Sendable {
    public let node: Int
    public let rect: Rect
    public let depth: Int
    public let isDir: Bool
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
                              maxDepth: Int = .max, minSide: Double = 1.0) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        layoutNode(index, node: root, rect: rect, depth: 0,
                   maxDepth: maxDepth, minSide: minSide, into: &tiles)
        return tiles
    }

    private static func layoutNode(_ index: FileIndex, node: Int, rect: Rect, depth: Int,
                                   maxDepth: Int, minSide: Double, into tiles: inout [TreemapTile]) {
        tiles.append(TreemapTile(node: node, rect: rect, depth: depth, isDir: index.nodes[node].isDir))
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
                       maxDepth: maxDepth, minSide: minSide, into: &tiles)
        }
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
