import Foundation
import Darwin
import CoreGraphics
import DiskScopeCore

/// Used bytes on the volume containing `path` — the denominator for a scan percentage.
func volumeUsedBytes(_ path: String) -> UInt64 {
    var s = statfs()
    guard statfs(path, &s) == 0, s.f_bsize > 0 else { return 0 }
    return UInt64(s.f_blocks - s.f_bfree) * UInt64(s.f_bsize)
}

/// View model: owns the scanned index and lays out treemap tiles on demand (cached by
/// canvas size so resizes/redraws don't re-run the layout every frame).
final class TreemapModel: ObservableObject {
    enum State: Equatable { case idle, scanning, ready }

    @Published var state: State = .idle
    @Published var path: String = ""
    @Published var fileCount: Int = 0
    @Published var dirCount: Int = 0
    @Published var totalSize: UInt64 = 0
    @Published var scanSeconds: Double = 0
    // Live scan progress.
    @Published var scannedCount: Int = 0
    @Published var scannedBytes: UInt64 = 0
    @Published var scanFraction: Double?   // nil = indeterminate (subfolder / unknown total)
    /// Per-extension breakdown, largest first — drives the legend pane.
    @Published var legend: [LegendEntry] = []

    private var index: FileIndex?
    private var cachedTiles: [TreemapTile] = []
    private var cachedSize: CGSize = .zero
    private var cushionCache: CGImage?
    private var cushionSize: CGSize = .zero

    func scan(_ p: String) {
        path = p
        state = .scanning
        scannedCount = 0; scannedBytes = 0; scanFraction = nil
        cachedTiles = []; cachedSize = .zero
        let t0 = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let volUsed = volumeUsedBytes(p)
            let idx = ParallelIndexBuilder.build(root: p) { c, b in
                let frac = volUsed > 0 ? min(0.99, Double(b) / Double(volUsed)) : nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scannedCount = c; self.scannedBytes = b; self.scanFraction = frac
                }
            }
            idx.aggregate()
            let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9

            // Tally bytes + count per extension for the legend.
            var bytesByExt: [String: UInt64] = [:]
            var countByExt: [String: Int] = [:]
            for n in idx.nodes where !n.isDir && !n.deleted {
                let e = extOf(n.name)
                bytesByExt[e, default: 0] += n.ownSize
                countByExt[e, default: 0] += 1
            }
            let total = max(1, idx.nodes.first?.totalSize ?? 1)
            var entries = bytesByExt.map { e, bytes in
                LegendEntry(ext: e, bytes: bytes, count: countByExt[e] ?? 0,
                            fraction: Double(bytes) / Double(total))
            }.sorted { $0.bytes > $1.bytes }
            // Keep the top slice; roll the long tail into one "other" row.
            let cap = 22
            if entries.count > cap {
                let tail = entries[cap...]
                let tailBytes = tail.reduce(UInt64(0)) { $0 + $1.bytes }
                let tailCount = tail.reduce(0) { $0 + $1.count }
                entries = Array(entries.prefix(cap)) + [LegendEntry(
                    ext: "·other", bytes: tailBytes, count: tailCount,
                    fraction: Double(tailBytes) / Double(total))]
            }
            let legend = entries

            DispatchQueue.main.async {
                guard let self else { return }
                self.index = idx
                self.fileCount = idx.fileCount
                self.dirCount = idx.dirCount
                self.totalSize = idx.nodes.first?.totalSize ?? 0
                self.scanSeconds = secs
                self.legend = legend
                self.state = .ready
            }
        }
    }

    /// Tiles laid out for the given canvas size (cached).
    func tiles(for size: CGSize) -> [TreemapTile] {
        guard let index, size.width > 4, size.height > 4 else { return [] }
        if size == cachedSize, !cachedTiles.isEmpty { return cachedTiles }
        cachedTiles = Treemap.layout(
            index, root: 0,
            in: Rect(x: 0, y: 0, w: Double(size.width), h: Double(size.height)),
            minSide: 2, cushionHeight: 0.42)
        cachedSize = size
        return cachedTiles
    }

    /// Cushion-shaded treemap bitmap for the given size (cached). The leaves are rendered
    /// as Phong-shaded pillows; selection/hover outlines are drawn over this by the view.
    func cushionImage(for size: CGSize) -> CGImage? {
        guard index != nil, size.width > 2, size.height > 2 else { return nil }
        if size == cushionSize, let c = cushionCache { return c }
        let w = Int(size.width), h = Int(size.height)
        let rgba = Treemap.renderCushionRGBA(tiles: tiles(for: size), width: w, height: h, ambient: 0.58) { [weak self] node in
            self.map { FilePalette.srgb(forExt: $0.ext(of: node)) } ?? (0.5, 0.5, 0.5)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        cushionCache = img; cushionSize = size
        return img
    }

    /// File extension for a node, for coloring.
    func ext(of node: Int) -> String {
        guard let index, node >= 0, node < index.nodes.count else { return "" }
        let name = index.nodes[node].name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Path + size for a node — used by hover readout.
    func info(for node: Int) -> (path: String, size: UInt64)? {
        guard let index, node >= 0, node < index.nodes.count else { return nil }
        let n = index.nodes[node]
        return (index.path(of: node), n.isDir ? n.totalSize : n.ownSize)
    }

    /// Root of the directory tree (the scanned folder), or nil before a scan completes.
    func makeRootNode() -> TreeNode? { index.map { TreeNode(id: 0, index: $0) } }
}

/// One row of the file-type legend.
struct LegendEntry: Identifiable {
    let ext: String        // "·other" / "(none)" are synthetic
    let bytes: UInt64
    let count: Int
    let fraction: Double
    var id: String { ext }
    var displayExt: String { ext.isEmpty ? "(none)" : (ext.hasPrefix("·") ? "other" : ".\(ext)") }
}

/// Extension (lowercased, no dot) of a filename, or "" if none.
func extOf(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return String(name[name.index(after: dot)...]).lowercased()
}

/// Human-readable byte size.
func humanSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) B" : String(format: "%.1f %@", v, units[i])
}
