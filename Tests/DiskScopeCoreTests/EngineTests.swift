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
        XCTAssertEqual(index.reconcile(directoryPath: root.path), ReconcileDelta(added: 1))
        XCTAssertEqual(index.search("new.txt").count, 1)
        XCTAssertEqual(index.fileCount, n + 1)
    }

    func testReconcileDelete() throws {
        let index = builtIndex()
        try fm.removeItem(at: root.appendingPathComponent("a.txt"))
        XCTAssertEqual(index.reconcile(directoryPath: root.path), ReconcileDelta(removed: 1))
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
