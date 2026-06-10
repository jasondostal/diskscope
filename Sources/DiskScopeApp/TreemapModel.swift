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
    var used = UInt64(s.f_blocks - s.f_bfree) * UInt64(s.f_bsize)
    // "/" is the small sealed SYSTEM volume (~12GB); the user's bytes live on the Data
    // volume firmlinked beside it. Without summing both, the denominator is ~60x short
    // and the progress bar pegs at 99% seconds into an honest multi-minute scan.
    if path == "/" {
        var d = statfs()
        if statfs("/System/Volumes/Data", &d) == 0, d.f_bsize > 0,
           (d.f_fsid.val.0, d.f_fsid.val.1) != (s.f_fsid.val.0, s.f_fsid.val.1) {
            used += UInt64(d.f_blocks - d.f_bfree) * UInt64(d.f_bsize)
        }
    }
    return used
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
    /// Directories the warm-start replay patched (nil = this was a full scan) — header info.
    @Published var warmReplayedDirs: Int?
    /// Quick Look target (Space / context menu); the view binds this to `.quickLookPreview`.
    @Published var quickLookURL: URL?
    /// Bumped on any index mutation (trash, live refresh) to force the views to re-render.
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
    // Pixel-space tile cache for the Retina cushion render — see scaledTiles(for:scale:).
    private var pixelTiles: [TreemapTile] = []
    private var pixelSize: CGSize = .zero
    private var pixelScale: CGFloat = 0
    private var cushionCache: CGImage?
    private var cushionSize: CGSize = .zero
    private var cushionScale: CGFloat = 0
    private var cushionHighlight: String?   // highlightExt the cached cushion was rendered for
    private var watcher: FSEventsWatcher?
    /// Live FSEvents auto-refresh — back ON: a flush is now incremental (reconcile patches
    /// subtree totals in O(depth) itself; the legend tables are patched from the deltas), so
    /// its cost is bounded by the changed directories, not the index size.
    private let liveRefreshEnabled = true
    // Live-refresh coalescing — see enqueueChanges.
    private var pendingDirs = Set<String>()
    private var pendingDeep = Set<String>() // ⊆ pendingDirs: needs a subtree reconcile
    private var liveRefreshScheduled = false
    private var lastLiveRefresh = DispatchTime.now()
    private let liveRefreshInterval = 2.0   // seconds — at most one pass per window
    // Legend source-of-truth tables: built once per scan, then PATCHED per reconcile delta
    // (the old full rebuild walked every node — O(files) per flush on a 1M-file home dir).
    private var bytesByExt: [String: UInt64] = [:]
    private var countByExt: [String: Int] = [:]
    /// FSEvents ID captured BEFORE the last scan touched the disk. An index saved with it
    /// can only over-replay on the next launch (reconcile is idempotent), never miss.
    private var preScanEventID: UInt64 = 0
    /// A WarmStart.save is serializing the node arena off-main — defer index mutations
    /// (flushChanges checks this) until it lands.
    private var snapshotInFlight = false
    private var terminateObserver: NSObjectProtocol?

    init() {
        // Persist the index on quit so the next launch warm-starts instead of cold-scanning.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveOnQuit() }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

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

    /// Optional recency-shading layer (off by default) — drains color from old files. Pushed in
    /// from ThemeManager; only the cushion bitmap is affected, not the layout.
    var recency = FilePalette.RecencyShading()
    func setRecency(_ r: FilePalette.RecencyShading) {
        guard r != recency else { return }
        recency = r
        cushionCache = nil
        revision += 1
    }

    /// Optional depth-shading layer (off by default) — mutes deeper-nested files so structure reads.
    var depth = FilePalette.DepthShading()
    func setDepth(_ d: FilePalette.DepthShading) {
        guard d != depth else { return }
        depth = d
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

    /// The node the treemap is laid out from (0 = the whole scan). Right-clicking a folder can
    /// re-root the map onto it — the TUI's drill-in, instant because it reuses the index.
    private(set) var treemapRoot = 0
    var isFocused: Bool { treemapRoot != 0 }

    func focusTreemap(on node: Int) {
        guard let index, node >= 0, node < index.nodes.count,
              index.nodes[node].isDir, node != treemapRoot else { return }
        treemapRoot = node
        invalidateRenderCaches()
        revision += 1
    }

    func clearTreemapFocus() {
        guard treemapRoot != 0 else { return }
        treemapRoot = 0
        invalidateRenderCaches()
        revision += 1
    }

    /// Basename of a node (the root shows its scanned-path basename).
    func name(of node: Int) -> String {
        guard let index, node >= 0, node < index.nodes.count else { return "" }
        let n = index.nodes[node].name
        return node == 0 ? (n.split(separator: "/").last.map(String.init) ?? n) : n
    }

    func isDir(_ node: Int) -> Bool {
        guard let index, node >= 0, node < index.nodes.count else { return false }
        return index.nodes[node].isDir
    }

    /// Scan (or warm-start) `rawPath`. `force` skips the warm-start snapshot — the header
    /// Refresh button uses it so "Rescan" always means a real walk of the disk.
    func scan(_ rawPath: String, force: Bool = false) {
        // Canonicalize so the index keys match the symlink-resolved paths FSEvents reports
        // (else live reconcile silently misses — the /tmp vs /private/tmp trap).
        let p = canonicalPath(rawPath)
        path = p
        state = .scanning
        scannedCount = 0; scannedBytes = 0; scanFraction = nil
        warmReplayedDirs = nil
        invalidateRenderCaches()
        treemapRoot = 0
        watcher?.stop(); watcher = nil
        pendingDirs.removeAll(); pendingDeep.removeAll()
        let t0 = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Capture BEFORE any disk work: a snapshot saved with this ID can only
            // over-replay next launch (reconcile is idempotent), never miss events.
            let preScanID = FSEventsWatcher.currentEventId()

            // Warm start: persisted index + FSEvents journal replay — skips the cold scan
            // entirely. Any doubt (no snapshot, journal wrapped, …) returns nil and we
            // fall through to the full build.
            if !force, let warm = WarmStart.load(root: p) {
                let idx = warm.index
                let files = idx.fileCount, dirs = idx.dirCount   // O(n) once, off-main
                let tables = buildExtTables(idx)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.adopt(idx, root: p, files: files, dirs: dirs, tables: tables,
                               seconds: warm.seconds, preScanID: preScanID)
                    self.warmReplayedDirs = warm.replayedDirs
                }
                return
            }

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
            let files = idx.fileCount, dirs = idx.dirCount
            let tables = buildExtTables(idx)

            DispatchQueue.main.async {
                guard let self else { return }
                self.adopt(idx, root: p, files: files, dirs: dirs, tables: tables,
                           seconds: secs, preScanID: preScanID)
                // Persist the fresh scan keyed to the pre-scan ID → next launch warm-starts.
                self.saveSnapshot(idx, root: p, eventID: preScanID)
            }
        }
    }

    /// Install a ready index (full scan or warm start) and start the live watcher.
    private func adopt(_ idx: FileIndex, root: String, files: Int, dirs: Int,
                       tables: (bytes: [String: UInt64], counts: [String: Int]),
                       seconds: Double, preScanID: UInt64) {
        index = idx
        preScanEventID = preScanID
        fileCount = files
        dirCount = dirs
        bytesByExt = tables.bytes
        countByExt = tables.counts
        totalSize = idx.nodes.first?.totalSize ?? 0
        scanSeconds = seconds
        legend = legendEntries()
        state = .ready
        if liveRefreshEnabled { startWatching(root) }
    }

    // MARK: - Live auto-refresh (FSEvents → reconcile)

    private func startWatching(_ root: String) {
        watcher?.stop()
        pendingDirs.removeAll(); pendingDeep.removeAll()
        let w = FSEventsWatcher(roots: [root]) { [weak self] dirs, deep in
            DispatchQueue.main.async { self?.enqueueChanges(dirs, deep: deep) }
        }
        // Journal wrapped, or the kernel demanded a rescan at/above the root — the whole
        // index is suspect; only a fresh full scan restores trust.
        w.onInvalidated = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scan(self.path, force: true)
            }
        }
        _ = w.start()
        watcher = w
    }

    /// Coalesce FSEvents batches and drain them at most once per `liveRefreshInterval` —
    /// bursts (builds, downloads) become one bounded pass instead of a pass per batch.
    private func enqueueChanges(_ dirs: [String], deep: Set<String>) {
        guard state == .ready else { return }
        pendingDirs.formUnion(dirs)
        pendingDeep.formUnion(deep)
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastLiveRefresh.uptimeNanoseconds) / 1e9
        let delay = max(0, liveRefreshInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flushChanges() }
    }

    /// Drain the pending dirs INCREMENTALLY: reconcile patches the subtree totals itself
    /// (O(depth)), and each delta patches the legend tables + counts. No aggregate(), no
    /// O(files) legend rebuild — the old full pass per flush is what kept live refresh off.
    private func flushChanges() {
        liveRefreshScheduled = false
        // A snapshot save is reading the node arena off-main — hold the mutation, retry.
        if snapshotInFlight {
            liveRefreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flushChanges() }
            return
        }
        lastLiveRefresh = DispatchTime.now()
        let dirs = pendingDirs; pendingDirs.removeAll()
        let deep = pendingDeep; pendingDeep.removeAll()
        guard let idx = index, state == .ready, !dirs.isEmpty else { return }
        var changed = false
        for d in dirs {
            let delta = deep.contains(d) ? idx.reconcileSubtree(directoryPath: d)
                                         : idx.reconcile(directoryPath: d)
            guard delta.changed else { continue }
            changed = true
            applyDelta(delta)
        }
        guard changed else { return }
        totalSize = idx.nodes.first?.totalSize ?? 0
        legend = legendEntries()
        invalidateRenderCaches()
        revision += 1
    }

    /// Fold one reconcile delta into the model's counters and legend tables. Clamped at 0:
    /// FSEvents over-delivery can transiently double-remove an entry.
    private func applyDelta(_ d: ReconcileDelta) {
        fileCount = max(0, fileCount + d.files)
        dirCount = max(0, dirCount + (d.items - d.files))   // items = files + dirs
        for (e, db) in d.extBytes where db != 0 {
            bytesByExt[e] = UInt64(max(0, Int64(bytesByExt[e] ?? 0) + db))
        }
        for (e, dc) in d.extCounts where dc != 0 {
            countByExt[e] = max(0, (countByExt[e] ?? 0) + dc)
        }
    }

    // MARK: - Warm-start persistence

    /// Persist the index off-main (utility — housekeeping). flushChanges defers mutations
    /// while the serializer reads the arena (`snapshotInFlight`).
    private func saveSnapshot(_ idx: FileIndex, root: String, eventID: UInt64) {
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            WarmStart.save(idx, root: root, eventID: eventID)
            DispatchQueue.main.async { self?.snapshotInFlight = false }
        }
    }

    /// Quit path: drain pending FSEvents into the index, then save synchronously (the
    /// process is about to die — async work would be lost). With a live watcher the index
    /// is current, so "now" is the right replay-from ID; without one, the pre-scan ID.
    private func saveOnQuit() {
        guard state == .ready, let idx = index, !snapshotInFlight else { return }
        flushChanges()
        let id = watcher != nil ? FSEventsWatcher.currentEventId() : preScanEventID
        WarmStart.save(idx, root: path, eventID: id)
    }

    // MARK: - Tiles + hit-testing

    /// Tiles laid out for the given canvas size (cached). Recomputing also rebuilds the
    /// hover hit-test grid.
    func tiles(for size: CGSize) -> [TreemapTile] {
        guard let index, size.width > 4, size.height > 4 else { return [] }
        if size == cachedSize, !cachedTiles.isEmpty { return cachedTiles }
        let root = (treemapRoot >= 0 && treemapRoot < index.nodes.count) ? treemapRoot : 0
        cachedTiles = Treemap.layout(
            index, root: root,
            in: Rect(x: 0, y: 0, w: Double(size.width), h: Double(size.height)),
            minSide: minSide, cushionHeight: 0.42)
        cachedSize = size
        rebuildGrid()
        return cachedTiles
    }

    // Hover hit-test grid: uniform ~32pt cells, each listing the LEAF tiles overlapping it.
    // A mouse-move then tests a handful of candidates instead of every tile (tens of
    // thousands on a dense map — the old per-move linear scan).
    private var grid: [[Int32]] = []
    private var gridCols = 0
    private var gridRows = 0
    private let gridCell = 32.0

    private func rebuildGrid() {
        gridCols = max(1, Int((Double(cachedSize.width) / gridCell).rounded(.up)))
        gridRows = max(1, Int((Double(cachedSize.height) / gridCell).rounded(.up)))
        grid = Array(repeating: [], count: gridCols * gridRows)
        for (i, t) in cachedTiles.enumerated() where !t.isDir {
            let r = t.rect
            guard r.w > 0, r.h > 0 else { continue }
            let x0 = max(0, min(gridCols - 1, Int(r.x / gridCell)))
            let x1 = max(0, min(gridCols - 1, Int((r.x + r.w) / gridCell)))
            let y0 = max(0, min(gridRows - 1, Int(r.y / gridCell)))
            let y1 = max(0, min(gridRows - 1, Int((r.y + r.h) / gridCell)))
            for cy in y0...y1 {
                for cx in x0...x1 { grid[cy * gridCols + cx].append(Int32(i)) }
            }
        }
    }

    private func contains(_ r: Rect, _ p: CGPoint) -> Bool {
        Double(p.x) >= r.x && Double(p.x) < r.x + r.w &&
        Double(p.y) >= r.y && Double(p.y) < r.y + r.h
    }

    /// Deepest LEAF (file) tile under `p`, via the grid. Assumes `tiles(for:)` ran for the
    /// current canvas size (the view's body does, before any hit-test can fire).
    func leafTile(at p: CGPoint) -> TreemapTile? {
        guard gridCols > 0, p.x >= 0, p.y >= 0,
              p.x < cachedSize.width, p.y < cachedSize.height else { return nil }
        let cx = min(gridCols - 1, Int(Double(p.x) / gridCell))
        let cy = min(gridRows - 1, Int(Double(p.y) / gridCell))
        var best: TreemapTile?
        for i in grid[cy * gridCols + cx] where contains(cachedTiles[Int(i)].rect, p) {
            best = cachedTiles[Int(i)]  // emitted parent-first → the last hit is the deepest
        }
        return best
    }

    /// Deepest DIRECTORY tile under `p`. The dir tiles containing a point form one
    /// ancestor chain (parent before child in the array), so the last match is the
    /// deepest; dirs are few enough that a linear scan is fine.
    func dirTile(at p: CGPoint) -> TreemapTile? {
        cachedTiles.last { $0.isDir && contains($0.rect, p) }
    }

    // MARK: - Cushion render

    /// Pixel-space tiles for the cushion render. TreemapTile's geometry is immutable
    /// outside Core (no public init), so instead of multiplying the cached point rects we
    /// lay out once at the scaled rect with a scaled minSide — squarify commutes with
    /// uniform scaling, so the tile SET matches the point-space cache used for hit-testing.
    /// Cached by (size, scale): this runs per resize, never per frame.
    private func scaledTiles(for size: CGSize, scale: CGFloat) -> [TreemapTile] {
        if scale == 1 { return tiles(for: size) }
        guard let index else { return [] }
        if size == pixelSize, scale == pixelScale, !pixelTiles.isEmpty { return pixelTiles }
        let root = (treemapRoot >= 0 && treemapRoot < index.nodes.count) ? treemapRoot : 0
        pixelTiles = Treemap.layout(
            index, root: root,
            in: Rect(x: 0, y: 0, w: Double(size.width * scale), h: Double(size.height * scale)),
            minSide: minSide * Double(scale), cushionHeight: 0.42)
        pixelSize = size; pixelScale = scale
        return pixelTiles
    }

    /// Cushion-shaded treemap bitmap at PIXEL resolution (size × displayScale), cached by
    /// (size, scale, highlight). Rendering in pixel space is what makes Retina crisp — the
    /// old point-resolution bitmap was upscaled by the GPU and looked blurry. Selection and
    /// hover outlines are drawn over this by the view, in point space.
    func cushionImage(for size: CGSize, scale: CGFloat) -> CGImage? {
        guard index != nil, size.width > 2, size.height > 2 else { return nil }
        if size == cushionSize, scale == cushionScale, cushionHighlight == highlightExt,
           let c = cushionCache { return c }
        let s = max(1, scale)
        let w = Int((size.width * s).rounded()), h = Int((size.height * s).rounded())
        let pal = palette
        let hl = highlightExt
        let bg = pal.background
        let rec = recency
        let dep = depth
        let now = Int64(Date().timeIntervalSince1970)
        let rgba = Treemap.renderCushionRGBA(tiles: scaledTiles(for: size, scale: s), width: w, height: h,
                                             background: pal.background, ambient: pal.ambient) { [weak self] tile in
            guard let self else { return (0.5, 0.5, 0.5) }
            if tile.isDir { return pal.dirFill } // backdrop under too-small-to-draw files
            let node = tile.node
            let e = self.ext(of: node)
            // Theme color, then the optional layers (each an identity when disabled).
            var base = rec.apply(pal.srgb(forExt: e), modTime: self.index?.nodes[node].modTime ?? 0, now: now)
            base = dep.apply(base, depth: tile.depth)
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
        cushionCache = img; cushionSize = size; cushionScale = scale; cushionHighlight = highlightExt
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

    // MARK: - Search (⌘F)

    /// Top matches by size. FileIndex.search caps the scan at `limit` hits (arena order);
    /// sorting after keeps the result list big-first for the UI.
    func search(_ q: String) -> [SearchResult] {
        guard let index else { return [] }
        return index.search(q, limit: 100).sorted { $0.size > $1.size }
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

    /// Quick Look the node (Space / context menu) — setting the URL presents the panel.
    func quickLook(_ node: Int) { quickLookURL = url(for: node) }

    /// Move a file/folder to the Trash and sync the index (reconcile its parent), so the
    /// treemap, tree, and legend all update without a full re-scan. Same incremental path
    /// as flushChanges: the delta patches the counters/tables — no aggregate, no rebuild.
    func moveToTrash(_ node: Int) {
        guard let idx = index, node > 0, let u = url(for: node) else { return }
        let parent = u.deletingLastPathComponent().path
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
            let delta = idx.reconcile(directoryPath: parent)
            applyDelta(delta)
            totalSize = idx.nodes.first?.totalSize ?? 0
            legend = legendEntries()
            invalidateRenderCaches()
            revision += 1
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Legend

    /// Sorted/capped legend rows derived from the tables + total (cheap — a few hundred
    /// extension keys, vs the old walk over every file node).
    private func legendEntries() -> [LegendEntry] {
        let total = max(1, totalSize)
        var entries = bytesByExt.compactMap { e, bytes -> LegendEntry? in
            let count = countByExt[e] ?? 0
            guard bytes > 0 || count > 0 else { return nil } // clamped-to-zero leftovers
            return LegendEntry(ext: e, bytes: bytes, count: count, fraction: Double(bytes) / Double(total))
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

    private func invalidateRenderCaches() {
        cachedTiles = []; cachedSize = .zero
        pixelTiles = []; pixelSize = .zero; pixelScale = 0
        cushionCache = nil; cushionSize = .zero; cushionScale = 0
        grid = []; gridCols = 0; gridRows = 0
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

/// Full per-extension tables — the legend's source of truth. Built once per scan; live
/// refresh and trash PATCH them from ReconcileDeltas instead of re-walking every node.
func buildExtTables(_ idx: FileIndex) -> (bytes: [String: UInt64], counts: [String: Int]) {
    var bytes: [String: UInt64] = [:]
    var counts: [String: Int] = [:]
    for n in idx.nodes where !n.isDir && !n.deleted {
        let e = extOf(n.name)
        bytes[e, default: 0] += n.ownSize
        counts[e, default: 0] += 1
    }
    return (bytes, counts)
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
