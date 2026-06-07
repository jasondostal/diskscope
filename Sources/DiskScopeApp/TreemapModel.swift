import Foundation
import Darwin
import CoreGraphics
import AppKit
import DiskScopeCore

/// Symlink-resolved absolute path (matches what FSEvents emits); unchanged if realpath fails.
func canonicalPath(_ p: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(p, &buf) != nil ? String(cString: buf) : p
}

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
    /// Bumped on any index mutation (trash) to force the views to re-render.
    @Published private(set) var revision = 0

    /// When set (a file extension, "" = no-extension), the treemap fades every tile that
    /// ISN'T that type so the matching ones pop. Driven by clicking a legend row.
    @Published var highlightExt: String? {
        didSet {
            guard oldValue != highlightExt else { return }
            cushionCache = nil // colors change, layout doesn't — only the bitmap is stale
            revision += 1
        }
    }

    private var index: FileIndex?
    private var cachedTiles: [TreemapTile] = []
    private var cachedSize: CGSize = .zero
    private var cushionCache: CGImage?
    private var cushionSize: CGSize = .zero
    private var cushionHighlight: String?   // highlightExt the cached cushion was rendered for
    private var watcher: FSEventsWatcher?
    /// Live FSEvents auto-refresh. OFF until it's reworked to be incremental + off-main; today's
    /// full-index pass per change pegs the CPU on a big active disk. Manual Refresh always works.
    private let liveRefreshEnabled = false
    // Live-refresh coalescing — see enqueueChanges.
    private var pendingDirs = Set<String>()
    private var liveRefreshScheduled = false
    private var lastLiveRefresh = DispatchTime.now()
    private let liveRefreshInterval = 2.0   // seconds — at most one heavy pass per window

    /// Current color palette (driven by the selected theme). Drives the cushion render and,
    /// via the views, the tree/legend colors.
    var palette = Theme.default.palette
    func setPalette(_ p: ThemePalette) {
        palette = p
        // Only colors / ambient / background changed — the tile geometry is identical, so keep
        // the (size-keyed) layout cache and re-render just the cushion bitmap. Re-laying-out the
        // whole index on every theme flip was the switch lag.
        cushionCache = nil
        revision += 1
    }

    /// Minimum on-screen cell size before the treemap stops subdividing (from Settings).
    var minSide: Double = 2
    func setMinSide(_ v: Double) {
        guard v != minSide else { return }
        minSide = v
        invalidateRenderCaches()
        revision += 1
    }

    func scan(_ rawPath: String) {
        // Canonicalize so the index keys match the symlink-resolved paths FSEvents reports
        // (else live reconcile silently misses — the /tmp vs /private/tmp trap).
        let p = canonicalPath(rawPath)
        path = p
        state = .scanning
        scannedCount = 0; scannedBytes = 0; scanFraction = nil
        cachedTiles = []; cachedSize = .zero
        watcher?.stop(); watcher = nil
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

            let legend = computeLegend(idx)

            DispatchQueue.main.async {
                guard let self else { return }
                self.index = idx
                self.fileCount = idx.fileCount
                self.dirCount = idx.dirCount
                self.totalSize = idx.nodes.first?.totalSize ?? 0
                self.scanSeconds = secs
                self.legend = legend
                self.state = .ready
                // Live FSEvents auto-refresh is OFF by default: on a huge, actively-churning
                // home dir (~1M files) a single refresh pass (reconcile + full aggregate + legend
                // + treemap re-render) can exceed the throttle window, so passes pile up and peg
                // the CPU. Use the manual Refresh button instead. Re-enable once it's incremental
                // and off-main. (FSEventsWatcher + enqueue/flush code is kept, just not started.)
                if self.liveRefreshEnabled { self.startWatching(p) }
            }
        }
    }

    // MARK: - Live auto-refresh (FSEvents → reconcile)

    private func startWatching(_ root: String) {
        watcher?.stop()
        pendingDirs.removeAll()
        let w = FSEventsWatcher(roots: [root]) { [weak self] dirs, _ in
            DispatchQueue.main.async { self?.enqueueChanges(dirs) }
        }
        _ = w.start()
        watcher = w
    }

    /// Coalesce FSEvents batches and run the heavy refresh at most once per `liveRefreshInterval`.
    /// Before this, reconcile + a full aggregate + a full legend rebuild (O(files): ~1M on a big
    /// home dir) ran on the MAIN THREAD for *every* batch — on an active disk that pegged a core
    /// and beachballed the UI. Now changes accumulate and one bounded pass drains them.
    private func enqueueChanges(_ dirs: [String]) {
        guard state == .ready else { return }
        pendingDirs.formUnion(dirs)
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastLiveRefresh.uptimeNanoseconds) / 1e9
        let delay = max(0, liveRefreshInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flushChanges() }
    }

    private func flushChanges() {
        liveRefreshScheduled = false
        lastLiveRefresh = DispatchTime.now()
        let dirs = pendingDirs; pendingDirs.removeAll()
        guard let idx = index, state == .ready, !dirs.isEmpty else { return }
        var changed = false
        for d in dirs where idx.reconcile(directoryPath: d).changed { changed = true }
        guard changed else { return }
        idx.aggregate()
        legend = computeLegend(idx)
        totalSize = idx.nodes.first?.totalSize ?? 0
        fileCount = idx.fileCount
        dirCount = idx.dirCount
        invalidateRenderCaches()
        revision += 1
    }

    /// Tiles laid out for the given canvas size (cached).
    func tiles(for size: CGSize) -> [TreemapTile] {
        guard let index, size.width > 4, size.height > 4 else { return [] }
        if size == cachedSize, !cachedTiles.isEmpty { return cachedTiles }
        cachedTiles = Treemap.layout(
            index, root: 0,
            in: Rect(x: 0, y: 0, w: Double(size.width), h: Double(size.height)),
            minSide: minSide, cushionHeight: 0.42)
        cachedSize = size
        return cachedTiles
    }

    /// Cushion-shaded treemap bitmap for the given size (cached). The leaves are rendered
    /// as Phong-shaded pillows; selection/hover outlines are drawn over this by the view.
    func cushionImage(for size: CGSize) -> CGImage? {
        guard index != nil, size.width > 2, size.height > 2 else { return nil }
        if size == cushionSize, cushionHighlight == highlightExt, let c = cushionCache { return c }
        let w = Int(size.width), h = Int(size.height)
        let pal = palette
        let hl = highlightExt
        let bg = pal.background
        let rgba = Treemap.renderCushionRGBA(tiles: tiles(for: size), width: w, height: h,
                                             background: pal.background, ambient: pal.ambient) { [weak self] node in
            guard let self else { return (0.5, 0.5, 0.5) }
            let e = self.ext(of: node)
            let base = pal.srgb(forExt: e)
            // Highlight mode: fade non-matching tiles toward the canvas so matches glow.
            if let hl, e != hl {
                return (base.r * 0.16 + bg.r * 0.5, base.g * 0.16 + bg.g * 0.5, base.b * 0.16 + bg.b * 0.5)
            }
            return base
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        cushionCache = img; cushionSize = size; cushionHighlight = highlightExt
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

    /// Rich stats for the inspector panel. `nil` selection falls back to the scanned root, so
    /// the panel always shows something useful.
    func stats(for node: Int?) -> NodeStats? {
        guard let index, !index.nodes.isEmpty else { return nil }
        let i = node ?? 0
        guard i >= 0, i < index.nodes.count, !index.nodes[i].deleted else { return nil }
        let n = index.nodes[i]
        let size = n.isDir ? n.totalSize : n.ownSize
        let total = index.nodes.first?.totalSize ?? 0
        let parent = Int(n.parent)
        let parentTotal = parent >= 0 ? index.nodes[parent].totalSize : total
        let e = ext(of: i)
        let name = i == 0 ? (n.name.split(separator: "/").last.map(String.init) ?? n.name) : n.name
        return NodeStats(
            node: i, name: name, path: index.path(of: i), isDir: n.isDir, isRoot: i == 0,
            size: size,
            fractionOfTotal: total > 0 ? Double(size) / Double(total) : 0,
            fractionOfParent: parentTotal > 0 ? Double(size) / Double(parentTotal) : 0,
            subtreeFiles: n.subtreeFiles, subtreeItems: n.subtreeItems,
            modTime: n.modTime, createTime: n.createTime,
            ext: e, category: FilePalette.category(forExt: e))
    }

    /// Root of the directory tree (the scanned folder), or nil before a scan completes.
    func makeRootNode() -> TreeNode? { index.map { TreeNode(id: 0, index: $0) } }

    /// Node ids from the root down to (and including) `node` — for expanding/revealing a
    /// selection in the tree.
    func ancestors(of node: Int) -> [Int] {
        guard let index, node >= 0, node < index.nodes.count else { return [] }
        var chain: [Int] = []
        var cur = node
        while cur >= 0 {
            chain.append(cur)
            let p = Int(index.nodes[cur].parent)
            if p < 0 { break }
            cur = p
        }
        return chain.reversed()
    }

    // MARK: - File actions

    func url(for node: Int) -> URL? {
        guard let index, node >= 0, node < index.nodes.count else { return nil }
        return URL(fileURLWithPath: index.path(of: node))
    }

    func reveal(_ node: Int) {
        guard let u = url(for: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func open(_ node: Int) {
        guard let u = url(for: node) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Move a file/folder to the Trash and sync the index (reconcile its parent), so the
    /// treemap, tree, and legend all update without a full re-scan.
    func moveToTrash(_ node: Int) {
        guard let idx = index, node > 0, let u = url(for: node) else { return }
        let parent = u.deletingLastPathComponent().path
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
            idx.reconcile(directoryPath: parent)
            idx.aggregate()
            legend = computeLegend(idx)
            totalSize = idx.nodes.first?.totalSize ?? 0
            fileCount = idx.fileCount
            dirCount = idx.dirCount
            invalidateRenderCaches()
            revision += 1
        } catch {
            NSSound.beep()
        }
    }

    private func invalidateRenderCaches() {
        cachedTiles = []; cachedSize = .zero
        cushionCache = nil; cushionSize = .zero
    }
}

/// Inspector stats for one node — what the right-pane details panel renders.
struct NodeStats {
    let node: Int
    let name: String
    let path: String
    let isDir: Bool
    let isRoot: Bool
    let size: UInt64
    let fractionOfTotal: Double
    let fractionOfParent: Double
    let subtreeFiles: Int32
    let subtreeItems: Int32
    let modTime: Int64
    let createTime: Int64
    let ext: String
    let category: FilePalette.Category
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

/// Build the per-extension legend (largest first, long tail folded into "other").
func computeLegend(_ idx: FileIndex) -> [LegendEntry] {
    var bytesByExt: [String: UInt64] = [:]
    var countByExt: [String: Int] = [:]
    for n in idx.nodes where !n.isDir && !n.deleted {
        let e = extOf(n.name)
        bytesByExt[e, default: 0] += n.ownSize
        countByExt[e, default: 0] += 1
    }
    let total = max(1, idx.nodes.first?.totalSize ?? 1)
    var entries = bytesByExt.map { e, bytes in
        LegendEntry(ext: e, bytes: bytes, count: countByExt[e] ?? 0, fraction: Double(bytes) / Double(total))
    }.sorted { $0.bytes > $1.bytes }
    let cap = 22
    if entries.count > cap {
        let tail = entries[cap...]
        let tailBytes = tail.reduce(UInt64(0)) { $0 + $1.bytes }
        let tailCount = tail.reduce(0) { $0 + $1.count }
        entries = Array(entries.prefix(cap)) + [LegendEntry(
            ext: "·other", bytes: tailBytes, count: tailCount, fraction: Double(tailBytes) / Double(total))]
    }
    return entries
}

/// Extension (lowercased, no dot) of a filename, or "" if none.
func extOf(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return String(name[name.index(after: dot)...]).lowercased()
}

/// Compact absolute date for the tree's Modified column. Cached formatter (DateFormatter
/// construction is costly and this is called per visible row). "—" for unknown (epoch 0).
private let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func shortDate(_ epoch: Int64) -> String {
    guard epoch > 0 else { return "—" }
    return shortDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

/// Human-readable byte size.
func humanSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) B" : String(format: "%.1f %@", v, units[i])
}
