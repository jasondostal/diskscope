import XCTest
@testable import DiskScopeCore

final class BulkScannerTests: XCTestCase {

    /// Build a known fixture tree on disk, scan it, assert the index reflects reality.
    /// This is the seam that matters: if parsing getattrlistbulk's packed buffer is off
    /// by a byte, counts go wrong here, not in production.
    func testScansKnownFixtureTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("diskscope-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // root/
        //   a.txt              (100 bytes)
        //   empty.txt          (0 bytes)
        //   sub/
        //     b.txt            (200 bytes)
        //     deep/
        //       c.txt          (50 bytes)
        try Data(count: 100).write(to: root.appendingPathComponent("a.txt"))
        try Data(count: 0).write(to: root.appendingPathComponent("empty.txt"))
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 200).write(to: sub.appendingPathComponent("b.txt"))
        let deep = sub.appendingPathComponent("deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 50).write(to: deep.appendingPathComponent("c.txt"))

        let stats = DiskScopeScanner.scan(path: root.path)

        XCTAssertEqual(stats.files, 4, "a.txt, empty.txt, b.txt, c.txt")
        XCTAssertEqual(stats.dirs, 2, "sub, deep")
        XCTAssertEqual(stats.errors, 0)
        // Allocated size is block-rounded up, so it meets-or-exceeds the logical 350 bytes.
        XCTAssertGreaterThanOrEqual(stats.allocBytes, 350)
    }

    /// A path that doesn't exist should fail cleanly as one error, not crash.
    func testMissingPathIsAnError() {
        let stats = DiskScopeScanner.scan(path: "/no/such/path/diskscope-\(UUID().uuidString)")
        XCTAssertEqual(stats.files, 0)
        XCTAssertEqual(stats.dirs, 0)
        XCTAssertEqual(stats.errors, 1)
    }
}
