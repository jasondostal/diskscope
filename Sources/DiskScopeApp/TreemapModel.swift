import Foundation
import DiskScopeCore

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

    private var index: FileIndex?
    private var cachedTiles: [TreemapTile] = []
    private var cachedSize: CGSize = .zero

    func scan(_ p: String) {
        path = p
        state = .scanning
        cachedTiles = []; cachedSize = .zero
        let t0 = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let idx = FileIndex()
            DiskScopeScanner.scan(path: p, into: idx)
            idx.aggregate()
            let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
            DispatchQueue.main.async {
                guard let self else { return }
                self.index = idx
                self.fileCount = idx.fileCount
                self.dirCount = idx.dirCount
                self.totalSize = idx.nodes.first?.totalSize ?? 0
                self.scanSeconds = secs
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
            minSide: 2)
        cachedSize = size
        return cachedTiles
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
}

/// Human-readable byte size.
func humanSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) B" : String(format: "%.1f %@", v, units[i])
}
