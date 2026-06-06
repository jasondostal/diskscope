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

} catch {
    print("fixture setup failed: \(error)")
    failures += 1
}

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
