import Foundation
import DiskScopeCore

// Minimal XCTest-free integration suite — runs under Command Line Tools (no full Xcode).
// Exits non-zero on any failure so it can gate CI / a pre-push hook.

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") } else { print("  ✗ FAIL: \(msg)"); failures += 1 }
}
func section(_ s: String) { print("\n\(s)") }

let fm = FileManager.default

/// Build a known fixture tree and return its root URL (caller removes it).
func makeFixture() throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("ds-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    // root/
    //   a.txt          (100 bytes)
    //   empty.txt      (0 bytes)
    //   sub/
    //     b.txt        (200 bytes)
    //     deep/ c.txt  (50 bytes)
    try Data(count: 100).write(to: root.appendingPathComponent("a.txt"))
    try Data(count: 0).write(to: root.appendingPathComponent("empty.txt"))
    let sub = root.appendingPathComponent("sub")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data(count: 200).write(to: sub.appendingPathComponent("b.txt"))
    let deep = sub.appendingPathComponent("deep")
    try fm.createDirectory(at: deep, withIntermediateDirectories: true)
    try Data(count: 50).write(to: deep.appendingPathComponent("c.txt"))
    return root
}

do {
    let root = try makeFixture()
    defer { try? fm.removeItem(at: root) }

    section("scanner → index build")
    let index = FileIndex()
    DiskScopeScanner.scan(path: root.path, into: index)
    index.aggregate()

    check(index.fileCount == 4, "4 files (a, empty, b, c) — got \(index.fileCount)")
    check(index.dirCount == 3, "3 dirs (root, sub, deep) — got \(index.dirCount)")
    check(index.unreadableCount == 0, "no unreadable dirs — got \(index.unreadableCount)")

    section("search")
    let bResults = index.search("b.txt")
    check(bResults.count == 1, "exactly one 'b.txt' — got \(bResults.count)")
    check(bResults.first?.path.hasSuffix("/sub/b.txt") == true,
          "b.txt path ends /sub/b.txt — got \(bResults.first?.path ?? "nil")")
    check(index.search("txt").count == 4, "substring 'txt' matches 4 files — got \(index.search("txt").count)")
    check(index.search("B.TXT").count == 1, "case-insensitive match — got \(index.search("B.TXT").count)")
    check(index.search("nonexistent-zzz").isEmpty, "no spurious matches")

    section("tree aggregation (treemap)")
    // Allocated size is block-rounded up, so the root subtree meets-or-exceeds 350 logical.
    check(index.nodes[0].totalSize >= 350, "root subtree >= 350 bytes — got \(index.nodes[0].totalSize)")
    // 'sub' subtree (b=200 + c=50) must exceed the root-only files when isolated:
    let subIdx = index.children(of: 0).first { index.nodes[$0].name == "sub" }
    check(subIdx != nil, "found 'sub' as a child of root")
    if let subIdx { check(index.nodes[subIdx].totalSize >= 250, "sub subtree >= 250 — got \(index.nodes[subIdx].totalSize)") }

    section("children enumeration")
    let rootKids = index.children(of: 0).map { index.nodes[$0].name }.sorted()
    check(rootKids == ["a.txt", "empty.txt", "sub"], "root children = a, empty, sub — got \(rootKids)")

    section("missing path is graceful")
    let empty = FileIndex()
    DiskScopeScanner.scan(path: "/no/such/path-\(UUID().uuidString)", into: empty)
    check(empty.unreadableCount == 1, "one unreadable for a missing root — got \(empty.unreadableCount)")

    // ---- Live reconcile: the Phase 1 bar (create / rename / delete reflected) ----
    section("reconcile: CREATE a new file")
    let live = FileIndex()
    DiskScopeScanner.scan(path: root.path, into: live)
    let baseFiles = live.fileCount
    try Data(count: 300).write(to: root.appendingPathComponent("new.txt"))
    var d = live.reconcile(directoryPath: root.path)
    check(d == ReconcileDelta(added: 1, removed: 0, updated: 0), "create → +1 added — got \(d)")
    check(live.search("new.txt").count == 1, "new.txt now searchable")
    check(live.fileCount == baseFiles + 1, "file count +1")

    section("reconcile: DELETE a file")
    try fm.removeItem(at: root.appendingPathComponent("a.txt"))
    d = live.reconcile(directoryPath: root.path)
    check(d == ReconcileDelta(added: 0, removed: 1, updated: 0), "delete → 1 removed — got \(d)")
    check(live.search("a.txt").isEmpty, "a.txt no longer searchable")

    section("reconcile: RENAME a file")
    try fm.moveItem(at: root.appendingPathComponent("empty.txt"),
                    to: root.appendingPathComponent("renamed.txt"))
    d = live.reconcile(directoryPath: root.path)
    check(d.added == 1 && d.removed == 1, "rename → +1 / -1 — got \(d)")
    check(live.search("empty.txt").isEmpty && live.search("renamed.txt").count == 1, "rename reflected")

    section("reconcile: CREATE a nested directory subtree (graft)")
    let newDir = root.appendingPathComponent("freshdir")
    try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
    try Data(count: 999).write(to: newDir.appendingPathComponent("nested.bin"))
    d = live.reconcile(directoryPath: root.path)
    check(d.added == 1, "new dir grafted as one add at this level — got \(d)")
    check(live.search("nested.bin").count == 1, "nested file inside grafted subtree is searchable")
    live.aggregate()
    check(live.nodes[0].totalSize >= 999, "aggregate picks up grafted subtree size")

    section("reconcile: DELETE a whole subtree")
    try fm.removeItem(at: root.appendingPathComponent("sub")) // had b.txt + deep/c.txt
    d = live.reconcile(directoryPath: root.path)
    check(d.removed == 1, "subtree removed as one tombstone at this level — got \(d)")
    check(live.search("b.txt").isEmpty && live.search("c.txt").isEmpty, "whole subtree gone from search")

    section("reconcile: UPDATE detection is idempotent")
    let before = live.reconcile(directoryPath: root.path)
    check(before == ReconcileDelta(), "re-reconcile with no fs change → no-op — got \(before)")

    // ---- Treemap layout (v1.1 — the WinDirStat view) ----
    section("treemap: squarify conserves area and stays in bounds")
    let canvas = Rect(x: 0, y: 0, w: 100, h: 60)
    let placed = Treemap.squarify(
        [(node: 1, size: 6), (node: 2, size: 6), (node: 3, size: 4), (node: 4, size: 3), (node: 5, size: 2)],
        in: canvas)
    check(placed.count == 5, "all 5 items placed — got \(placed.count)")
    let placedArea: Double = placed.map(\.rect.area).reduce(0, +)
    check(abs(placedArea - canvas.area) / canvas.area < 0.001, "placed area ≈ canvas area — got \(placedArea) vs \(canvas.area)")
    let inBounds = placed.allSatisfy {
        $0.rect.x >= -0.001 && $0.rect.y >= -0.001 &&
        $0.rect.x + $0.rect.w <= canvas.w + 0.001 && $0.rect.y + $0.rect.h <= canvas.h + 0.001
    }
    check(inBounds, "every cell within the canvas")
    // Area is proportional to size: node 1 (size 6) cell should be ~3x node 5 (size 2).
    let a1 = placed.first { $0.node == 1 }!.rect.area
    let a5 = placed.first { $0.node == 5 }!.rect.area
    check(abs(a1 / a5 - 3.0) < 0.01, "cell area ∝ size (6/2 = 3) — got \(a1 / a5)")

    section("treemap: full layout over the index")
    let tindex = FileIndex()
    DiskScopeScanner.scan(path: root.path, into: tindex)
    tindex.aggregate()
    let tiles = Treemap.layout(tindex, root: 0, in: Rect(x: 0, y: 0, w: 800, h: 600), minSide: 1)
    check(!tiles.isEmpty, "produced tiles — got \(tiles.count)")
    check(tiles.allSatisfy { $0.rect.x >= -0.5 && $0.rect.y >= -0.5 && $0.rect.x + $0.rect.w <= 800.5 && $0.rect.y + $0.rect.h <= 600.5 },
          "all tiles within the 800×600 canvas")
    // Leaf (file) tiles should tile the canvas: their areas sum to ≈ the whole canvas.
    let leafArea: Double = tiles.filter { !$0.isDir }.map(\.rect.area).reduce(0, +)
    check(leafArea > 800 * 600 * 0.80, "file cells cover most of the canvas — got \(Int(leafArea)) / \(800 * 600)")

} catch {
    print("fixture setup failed: \(error)")
    failures += 1
}

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
