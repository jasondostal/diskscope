import XCTest
@testable import DiskScopeCore

/// The canonical engine suite. Builds a known fixture tree on disk and asserts the
/// scanner → index → search → aggregate → reconcile → treemap pipeline against it.
final class EngineTests: XCTestCase {

    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // root/
        //   a.txt (100)  empty.txt (0)
        //   sub/ b.txt (200)  deep/ c.txt (50)
        try Data(count: 100).write(to: root.appendingPathComponent("a.txt"))
        try Data(count: 0).write(to: root.appendingPathComponent("empty.txt"))
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 200).write(to: sub.appendingPathComponent("b.txt"))
        let deep = sub.appendingPathComponent("deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 50).write(to: deep.appendingPathComponent("c.txt"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func builtIndex() -> FileIndex {
        let index = FileIndex()
        DiskScopeScanner.scan(path: root.path, into: index)
        index.aggregate()
        return index
    }

    // MARK: - Scan / build

    func testScanBuildsIndex() {
        let index = builtIndex()
        XCTAssertEqual(index.fileCount, 4, "a, empty, b, c")
        XCTAssertEqual(index.dirCount, 3, "root, sub, deep")
        XCTAssertEqual(index.unreadableCount, 0)
    }

    func testMissingRootIsGraceful() {
        let index = FileIndex()
        DiskScopeScanner.scan(path: "/no/such/\(UUID().uuidString)", into: index)
        XCTAssertEqual(index.unreadableCount, 1)
        XCTAssertEqual(index.fileCount, 0)
    }

    // MARK: - Search

    func testSearch() {
        let index = builtIndex()
        XCTAssertEqual(index.search("b.txt").count, 1)
        XCTAssertTrue(index.search("b.txt").first?.path.hasSuffix("/sub/b.txt") == true)
        XCTAssertEqual(index.search("txt").count, 4, "substring matches all four")
        XCTAssertEqual(index.search("B.TXT").count, 1, "case-insensitive")
        XCTAssertTrue(index.search("nonexistent-zzz").isEmpty)
    }

    // MARK: - Search engine (blob + memmem + ranking)

    /// Prefix beats word-start beats mid-word; within a rank, bigger first.
    func testSearchRanking() {
        let index = FileIndex()
        let root = index.directory(parent: -1, name: "/r", allocSize: 0, modTime: 0, createTime: 0)
        index.file(parent: root, name: "report.pdf", allocSize: 100, modTime: 0, createTime: 0)   // mid-word "port"
        index.file(parent: root, name: "my-port.txt", allocSize: 100, modTime: 0, createTime: 0)  // word-start
        index.file(parent: root, name: "portal.log", allocSize: 100, modTime: 0, createTime: 0)   // prefix, smaller
        index.file(parent: root, name: "PORTABLE.bin", allocSize: 999, modTime: 0, createTime: 0) // prefix, bigger
        index.aggregate()
        let names = index.search("port").map(\.name)
        XCTAssertEqual(names, ["PORTABLE.bin", "portal.log", "my-port.txt", "report.pdf"])
    }

    /// The '/' separator makes cross-name matches impossible, and '/' queries match nothing.
    func testSearchNeverMatchesAcrossNames() {
        let index = FileIndex()
        let root = index.directory(parent: -1, name: "/r", allocSize: 0, modTime: 0, createTime: 0)
        index.file(parent: root, name: "xy", allocSize: 1, modTime: 0, createTime: 0)
        index.file(parent: root, name: "zw", allocSize: 1, modTime: 0, createTime: 0)
        index.aggregate()
        XCTAssertTrue(index.search("yz").isEmpty, "no phantom match spanning two names")
        XCTAssertTrue(index.search("y/z").isEmpty, "'/' can't appear in a name")
        XCTAssertEqual(index.search("xy").count, 1)
    }

    /// The Everything contract: keystroke-speed queries on a big index. 200k synthetic
    /// names, generous 100ms budget (typical is single-digit ms in release).
    func testSearchLatencyOnLargeIndex() {
        let index = FileIndex()
        let root = index.directory(parent: -1, name: "/big", allocSize: 0, modTime: 0, createTime: 0)
        for i in 0..<200_000 {
            index.file(parent: root, name: "file-\(i)-some-longer-name.dat",
                       allocSize: UInt64(i), modTime: 0, createTime: 0)
        }
        index.file(parent: root, name: "the-needle-in-question.gguf", allocSize: 5, modTime: 0, createTime: 0)
        index.aggregate()
        let t0 = DispatchTime.now()
        let hits = index.search("needle-in")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssertEqual(hits.count, 1)
        XCTAssertLessThan(ms, 100, "blob sweep must stay keystroke-fast (was \(ms)ms)")
        // Broad query exercises the hit cap + ranking path without blowing up.
        XCTAssertEqual(index.search("file-", limit: 50).count, 50)
    }

    // MARK: - Aggregation / children

    func testAggregateAndChildren() {
        let index = builtIndex()
        XCTAssertGreaterThanOrEqual(index.nodes[0].totalSize, 350, "root subtree rolls up")
        let subIdx = index.children(of: 0).first { index.nodes[$0].name == "sub" }
        XCTAssertNotNil(subIdx)
        XCTAssertGreaterThanOrEqual(index.nodes[subIdx!].totalSize, 250)
        let rootKids = index.children(of: 0).map { index.nodes[$0].name }.sorted()
        XCTAssertEqual(rootKids, ["a.txt", "empty.txt", "sub"])
    }

    func testParallelBuildMatchesSerial() {
        let serial = builtIndex()
        let par = ParallelIndexBuilder.build(root: root.path, workers: 4)
        par.aggregate()
        XCTAssertEqual(par.fileCount, serial.fileCount, "same file count")
        XCTAssertEqual(par.dirCount, serial.dirCount, "same dir count")
        XCTAssertEqual(par.nodes[0].totalSize, serial.nodes[0].totalSize, "same total size")
        XCTAssertEqual(Set(par.search("txt").map(\.path)),
                       Set(serial.search("txt").map(\.path)), "same files found")
    }

    func testSubtreeCounts() {
        let index = builtIndex()
        // root: files a, empty, b, c (4); items a, empty, sub, deep, b, c (6)
        XCTAssertEqual(index.nodes[0].subtreeFiles, 4)
        XCTAssertEqual(index.nodes[0].subtreeItems, 6)
        let subIdx = index.children(of: 0).first { index.nodes[$0].name == "sub" }!
        XCTAssertEqual(index.nodes[subIdx].subtreeFiles, 2, "b.txt + c.txt")
        XCTAssertEqual(index.nodes[subIdx].subtreeItems, 3, "deep, b.txt, c.txt")
    }

    // MARK: - Live reconcile (the FSEvents patch target)

    func testReconcileCreate() throws {
        let index = builtIndex()
        let n = index.fileCount
        try Data(count: 300).write(to: root.appendingPathComponent("new.txt"))
        let d = index.reconcile(directoryPath: root.path)
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 0); XCTAssertEqual(d.updated, 0)
        XCTAssertGreaterThanOrEqual(d.bytes, 300, "delta carries the new bytes")
        XCTAssertGreaterThanOrEqual(d.extBytes["txt"] ?? 0, 300, "per-ext delta for legends")
        XCTAssertEqual(index.search("new.txt").count, 1)
        XCTAssertEqual(index.fileCount, n + 1)
    }

    func testReconcileDelete() throws {
        let index = builtIndex()
        try fm.removeItem(at: root.appendingPathComponent("a.txt"))
        let d = index.reconcile(directoryPath: root.path)
        XCTAssertEqual(d.added, 0); XCTAssertEqual(d.removed, 1); XCTAssertEqual(d.updated, 0)
        XCTAssertLessThan(d.bytes, 0, "removed bytes are negative")
        XCTAssertTrue(index.search("a.txt").isEmpty)
    }

    func testReconcileRename() throws {
        let index = builtIndex()
        try fm.moveItem(at: root.appendingPathComponent("empty.txt"),
                        to: root.appendingPathComponent("renamed.txt"))
        let d = index.reconcile(directoryPath: root.path)
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 1)
        XCTAssertTrue(index.search("empty.txt").isEmpty)
        XCTAssertEqual(index.search("renamed.txt").count, 1)
    }

    func testReconcileGraftsNewSubtree() throws {
        let index = builtIndex()
        let newDir = root.appendingPathComponent("freshdir")
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data(count: 999).write(to: newDir.appendingPathComponent("nested.bin"))
        XCTAssertEqual(index.reconcile(directoryPath: root.path).added, 1, "grafted as one add here")
        XCTAssertEqual(index.search("nested.bin").count, 1, "nested file searchable")
        index.aggregate()
        XCTAssertGreaterThanOrEqual(index.nodes[0].totalSize, 999)
    }

    func testReconcileRemovesSubtreeAndIsIdempotent() throws {
        let index = builtIndex()
        try fm.removeItem(at: root.appendingPathComponent("sub")) // b.txt + deep/c.txt
        XCTAssertEqual(index.reconcile(directoryPath: root.path).removed, 1)
        XCTAssertTrue(index.search("b.txt").isEmpty && index.search("c.txt").isEmpty)
        XCTAssertEqual(index.reconcile(directoryPath: root.path), ReconcileDelta(), "no-op when unchanged")
    }

    // MARK: - Incremental aggregate (reconcile patches ancestors in O(depth))

    /// After arbitrary reconciles WITHOUT a full aggregate(), the totals must already be
    /// what a full aggregate would compute — that's the contract that lets live refresh
    /// drop the O(n) pass.
    func testIncrementalAggregateMatchesFull() throws {
        let index = builtIndex()
        // Mutate: grow a file, delete one, add one, graft a subtree, then reconcile.
        try Data(count: 5000).write(to: root.appendingPathComponent("sub/b.txt"))
        try fm.removeItem(at: root.appendingPathComponent("a.txt"))
        try Data(count: 700).write(to: root.appendingPathComponent("added.bin"))
        let newDir = root.appendingPathComponent("sub/deep/newdir")
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data(count: 1234).write(to: newDir.appendingPathComponent("inner.dat"))

        index.reconcile(directoryPath: root.path)
        index.reconcile(directoryPath: root.appendingPathComponent("sub").path)
        index.reconcile(directoryPath: root.appendingPathComponent("sub/deep").path)

        let liveTotals = index.nodes.indices.filter { !index.nodes[$0].deleted }
            .map { (index.nodes[$0].totalSize, index.nodes[$0].subtreeFiles, index.nodes[$0].subtreeItems) }
        index.aggregate()
        let fullTotals = index.nodes.indices.filter { !index.nodes[$0].deleted }
            .map { (index.nodes[$0].totalSize, index.nodes[$0].subtreeFiles, index.nodes[$0].subtreeItems) }
        for (i, (live, full)) in zip(liveTotals, fullTotals).enumerated() {
            XCTAssertEqual(live.0, full.0, "totalSize matches full aggregate at #\(i)")
            XCTAssertEqual(live.1, full.1, "subtreeFiles matches at #\(i)")
            XCTAssertEqual(live.2, full.2, "subtreeItems matches at #\(i)")
        }
    }

    func testReconcileSubtreeRegrafts() throws {
        let index = builtIndex()
        try Data(count: 4096).write(to: root.appendingPathComponent("sub/deep/d2.txt"))
        index.reconcileSubtree(directoryPath: root.appendingPathComponent("sub").path)
        XCTAssertEqual(index.search("d2.txt").count, 1)
        XCTAssertEqual(index.search("c.txt").count, 1, "old content re-grafted, not lost")
        // Totals patched incrementally must equal a full recompute.
        let live = index.nodes[0].totalSize
        index.aggregate()
        XCTAssertEqual(live, index.nodes[0].totalSize)
    }

    // MARK: - Reclaimables helpers

    func testNodeForPath() {
        let index = builtIndex()
        XCTAssertNotNil(index.node(forPath: root.path + "/sub"), "directory resolves")
        XCTAssertNotNil(index.node(forPath: root.path + "/sub/b.txt"), "file resolves via parent")
        XCTAssertNil(index.node(forPath: root.path + "/sub/nope.txt"))
        XCTAssertNil(index.node(forPath: "/not/in/scan"))
    }

    func testAggregateDirsTopmostOnly() throws {
        // root/node_modules/a.bin + root/node_modules/nested/node_modules/b.bin —
        // the nested one must NOT double-count (it's inside the topmost's totalSize).
        let nm = root.appendingPathComponent("node_modules")
        let nested = nm.appendingPathComponent("nested/node_modules")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: nm.appendingPathComponent("a.bin"))
        try Data(count: 4096).write(to: nested.appendingPathComponent("b.bin"))
        let index = builtIndex()
        let agg = index.aggregateDirs(named: "node_modules")
        XCTAssertEqual(agg.count, 1, "only the topmost node_modules counts")
        let topmost = index.node(forPath: nm.path)!
        XCTAssertEqual(agg.bytes, index.nodes[topmost].totalSize, "bytes = topmost subtree")
        XCTAssertGreaterThanOrEqual(agg.bytes, 8192, "includes the nested file once")
    }

    // MARK: - IndexStore (persistent snapshot round-trip)

    func testIndexStoreRoundTrip() throws {
        let index = builtIndex()
        try IndexStore.save(index, root: root.path, eventID: 42)
        defer { try? fm.removeItem(at: IndexStore.url(forRoot: root.path)) }

        let loaded = IndexStore.load(root: root.path)
        XCTAssertNotNil(loaded)
        let (restored, eventID) = loaded!
        XCTAssertEqual(eventID, 42)
        restored.aggregate()
        XCTAssertEqual(restored.fileCount, index.fileCount)
        XCTAssertEqual(restored.dirCount, index.dirCount)
        XCTAssertEqual(restored.nodes[0].totalSize, index.nodes[0].totalSize)
        XCTAssertEqual(Set(restored.search("txt").map(\.path)), Set(index.search("txt").map(\.path)))

        // The restored index must still reconcile (path maps rebuilt correctly).
        try Data(count: 300).write(to: root.appendingPathComponent("afterload.txt"))
        XCTAssertEqual(restored.reconcile(directoryPath: root.path).added, 1)
        XCTAssertEqual(restored.search("afterload.txt").count, 1)
    }

    func testIndexStoreRejectsWrongRoot() throws {
        let index = builtIndex()
        try IndexStore.save(index, root: root.path, eventID: 1)
        defer { try? fm.removeItem(at: IndexStore.url(forRoot: root.path)) }
        XCTAssertNil(IndexStore.load(root: "/somewhere/else"), "wrong root → no snapshot")
    }

    // MARK: - Timestamps (mtime/crtime threaded from getattrlistbulk)

    /// Locks the getattrlistbulk buffer packing order: adding the two common-attr timespecs
    /// must NOT shift the file-attr (allocSize) offset. Exact sizes prove the cursor walk.
    func testSizesExactAfterAddingTimeAttrs() {
        let index = builtIndex()
        func own(_ name: String) -> UInt64 {
            let i = index.nodes.firstIndex { $0.name == name && !$0.isDir }!
            return index.nodes[i].ownSize
        }
        // Allocated (block-rounded) size ≥ logical; a 100-byte file is one 4K block, etc.
        // The zero-byte file must allocate zero — the tell-tale that the offset didn't drift.
        XCTAssertEqual(own("empty.txt"), 0, "0-byte file allocates 0 (offset not drifted)")
        XCTAssertGreaterThanOrEqual(own("a.txt"), 100)
        XCTAssertGreaterThanOrEqual(own("b.txt"), 200)
    }

    func testScanCapturesModTime() throws {
        // Stamp a known mtime so the assertion is deterministic.
        let when = Date(timeIntervalSince1970: 1_600_000_000) // 2020-09-13
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        let index = builtIndex()
        let i = index.nodes.firstIndex { $0.name == "a.txt" && !$0.isDir }!
        XCTAssertEqual(index.nodes[i].modTime, 1_600_000_000, "stamped mtime threaded through")
        // Directories carry their own mtime too (recently created → nonzero).
        let subIdx = index.children(of: 0).first { index.nodes[$0].name == "sub" }!
        XCTAssertGreaterThan(index.nodes[subIdx].modTime, 0, "dir mtime captured")
    }

    func testParallelBuildCapturesSameModTimes() throws {
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        let serial = builtIndex()
        let par = ParallelIndexBuilder.build(root: root.path); par.aggregate()
        func mtime(_ idx: FileIndex, _ name: String) -> Int64 {
            idx.nodes[idx.nodes.firstIndex { $0.name == name && !$0.isDir }!].modTime
        }
        XCTAssertEqual(mtime(par, "a.txt"), 1_600_000_000)
        XCTAssertEqual(mtime(par, "a.txt"), mtime(serial, "a.txt"), "parallel == serial mtime")
    }

    func testReconcileUpdatesModTime() throws {
        let index = builtIndex()
        let i = index.nodes.firstIndex { $0.name == "a.txt" && !$0.isDir }!
        let old = index.nodes[i].modTime
        let when = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        XCTAssertNotEqual(old, 1_700_000_000)
        XCTAssertEqual(index.reconcile(directoryPath: root.path).updated, 1, "mtime change is an update")
        XCTAssertEqual(index.nodes[i].modTime, 1_700_000_000, "reconcile refreshed mtime")
    }

    // MARK: - Treemap layout

    func testSquarifyConservesAreaInBounds() {
        let canvas = Rect(x: 0, y: 0, w: 100, h: 60)
        let placed = Treemap.squarify(
            [(1, 6.0), (2, 6.0), (3, 4.0), (4, 3.0), (5, 2.0)].map { (node: $0.0, size: $0.1) },
            in: canvas)
        XCTAssertEqual(placed.count, 5)
        let area = placed.map(\.rect.area).reduce(0, +)
        XCTAssertEqual(area, canvas.area, accuracy: 0.001)
        XCTAssertTrue(placed.allSatisfy {
            $0.rect.x >= -0.001 && $0.rect.y >= -0.001 &&
            $0.rect.x + $0.rect.w <= canvas.w + 0.001 && $0.rect.y + $0.rect.h <= canvas.h + 0.001
        })
        let a1 = placed.first { $0.node == 1 }!.rect.area
        let a5 = placed.first { $0.node == 5 }!.rect.area
        XCTAssertEqual(a1 / a5, 3.0, accuracy: 0.01, "area ∝ size")
    }

    /// The TUI drills in by laying out the subtree rooted at the focused folder — not just
    /// node 0. Lock that any node can be a layout root and its files fill the canvas.
    func testLayoutOfSubtreeRoot() {
        let index = builtIndex()
        let subIdx = index.children(of: 0).first { index.nodes[$0].name == "sub" }!
        let canvas = Rect(x: 0, y: 0, w: 400, h: 300)
        let tiles = Treemap.layout(index, root: subIdx, in: canvas, minSide: 1)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertEqual(tiles.first?.node, subIdx, "first tile is the requested root")
        // Only sub's descendants appear — a.txt (a root-level file) must not.
        let aIdx = index.children(of: 0).first { index.nodes[$0].name == "a.txt" }!
        XCTAssertFalse(tiles.contains { $0.node == aIdx }, "siblings of the root aren't laid out")
        let leafArea = tiles.filter { !$0.isDir }.map(\.rect.area).reduce(0, +)
        XCTAssertGreaterThan(leafArea, canvas.area * 0.80)
    }

    func testFullTreemapLayout() {
        let index = builtIndex()
        let canvas = Rect(x: 0, y: 0, w: 800, h: 600)
        let tiles = Treemap.layout(index, root: 0, in: canvas, minSide: 1)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy {
            $0.rect.x >= -0.5 && $0.rect.y >= -0.5 &&
            $0.rect.x + $0.rect.w <= canvas.w + 0.5 && $0.rect.y + $0.rect.h <= canvas.h + 0.5
        })
        let leafArea = tiles.filter { !$0.isDir }.map(\.rect.area).reduce(0, +)
        XCTAssertGreaterThan(leafArea, canvas.area * 0.80, "files cover most of the canvas")
    }
}
