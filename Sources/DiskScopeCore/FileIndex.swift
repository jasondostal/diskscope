import Foundation

/// One entry in the index. Stored in a flat array (arena); relationships are array
/// indices, not pointers — cache-friendly, and supports both a linear name scan (search)
/// and tree aggregation (treemap) over the same structure.
public struct IndexNode {
    public var name: String
    public var parent: Int32       // -1 for the root
    public var firstChild: Int32 = -1
    public var nextSibling: Int32 = -1
    public var ownSize: UInt64     // a file's allocated bytes; 0 for directories
    public var totalSize: UInt64 = 0 // subtree sum, filled by aggregate()
    public var isDir: Bool
}

public struct SearchResult {
    public let node: Int
    public let name: String
    public let path: String
    public let size: UInt64
    public let isDir: Bool
}

/// The index engine — the product. Both v1.0 search and v1.1 treemap are clients of this.
///
/// MVP scope, real architecture: a flat node arena with index-linked children. Names are
/// plain Strings and search is a tight linear scan for now — the handoff says measure
/// before reaching for a suffix automaton, and millions of short strings scan fast.
/// Nothing here leaks the storage choice, so the scan-vs-suffix-structure decision stays
/// swappable behind this interface.
public final class FileIndex: ScanSink {

    public private(set) var nodes: [IndexNode] = []
    public private(set) var unreadableCount = 0

    public init() {}

    public var count: Int { nodes.count }
    public var fileCount: Int { nodes.lazy.filter { !$0.isDir }.count }
    public var dirCount: Int { nodes.lazy.filter { $0.isDir }.count }

    // MARK: - ScanSink (build path)

    public func directory(parent: Int, name: String, allocSize: UInt64) -> Int {
        append(IndexNode(name: name, parent: Int32(parent), ownSize: 0, isDir: true), parent: parent)
    }

    public func file(parent: Int, name: String, allocSize: UInt64) {
        _ = append(IndexNode(name: name, parent: Int32(parent), ownSize: allocSize, isDir: false), parent: parent)
    }

    public func unreadable() { unreadableCount += 1 }

    @discardableResult
    private func append(_ node: IndexNode, parent: Int) -> Int {
        let idx = nodes.count
        nodes.append(node)
        if parent >= 0 {
            // Prepend into the parent's child list (O(1)); order within a dir isn't
            // promised. The scanner appends a dir before its children, so parent < child.
            nodes[idx].nextSibling = nodes[parent].firstChild
            nodes[parent].firstChild = Int32(idx)
        }
        return idx
    }

    // MARK: - Aggregation (treemap)

    /// Roll up each subtree's total allocated size. One reverse pass works because the
    /// scanner emits every parent before its children, so parent index < child index.
    public func aggregate() {
        for i in nodes.indices { nodes[i].totalSize = nodes[i].ownSize }
        var i = nodes.count - 1
        while i > 0 {
            let p = Int(nodes[i].parent)
            if p >= 0 { nodes[p].totalSize += nodes[i].totalSize }
            i -= 1
        }
    }

    /// Immediate children of a node, as index values (for treemap drill-down).
    public func children(of index: Int) -> [Int] {
        var out: [Int] = []
        var c = nodes[index].firstChild
        while c >= 0 { out.append(Int(c)); c = nodes[Int(c)].nextSibling }
        return out
    }

    // MARK: - Search (v1.0)

    /// Case-insensitive substring match over every name. Linear scan — the deliberate
    /// v1 baseline to measure before optimizing.
    public func search(_ query: String, limit: Int = 1000) -> [SearchResult] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var out: [SearchResult] = []
        for i in nodes.indices {
            if nodes[i].name.lowercased().contains(needle) {
                out.append(result(for: i))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Reconstruct an absolute path by walking parent links to the root.
    public func path(of index: Int) -> String {
        var comps: [String] = []
        var cur = index
        while cur > 0 { comps.append(nodes[cur].name); cur = Int(nodes[cur].parent) }
        let base = nodes.isEmpty ? "" : nodes[0].name // root holds the full scanned path
        return comps.isEmpty ? base : base + "/" + comps.reversed().joined(separator: "/")
    }

    private func result(for index: Int) -> SearchResult {
        let n = nodes[index]
        return SearchResult(node: index, name: n.name, path: path(of: index),
                            size: n.isDir ? n.totalSize : n.ownSize, isDir: n.isDir)
    }
}
