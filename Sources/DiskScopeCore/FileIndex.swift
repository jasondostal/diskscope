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
    public var deleted: Bool = false // tombstone — live reconcile removes by marking
    // Descendant counts, filled by aggregate() (WinDirStat's "Files" / "Items" columns).
    public var subtreeFiles: Int32 = 0 // files anywhere under this node
    public var subtreeItems: Int32 = 0 // all entries (files + dirs) under this node
}

/// What a single reconcile changed — for logging / Live-Wire UI deltas.
public struct ReconcileDelta: Sendable, Equatable {
    public var added = 0
    public var removed = 0
    public var updated = 0
    public init(added: Int = 0, removed: Int = 0, updated: Int = 0) {
        self.added = added; self.removed = removed; self.updated = updated
    }
    public var changed: Bool { added + removed + updated > 0 }
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

    // Directory path <-> node index, maintained during build so live reconcile can find
    // the node for a changed directory in O(1). Only directories are tracked (far fewer
    // than files, and reconcile always targets a directory).
    private var dirPath: [Int: String] = [:]
    private var pathToDir: [String: Int] = [:]

    public init() {}

    public var count: Int { nodes.lazy.filter { !$0.deleted }.count }
    public var fileCount: Int { nodes.lazy.filter { !$0.isDir && !$0.deleted }.count }
    public var dirCount: Int { nodes.lazy.filter { $0.isDir && !$0.deleted }.count }

    // MARK: - ScanSink (build path)

    public func directory(parent: Int, name: String, allocSize: UInt64) -> Int {
        let idx = append(IndexNode(name: name, parent: Int32(parent), ownSize: 0, isDir: true), parent: parent)
        // Root (parent -1) carries the full scanned path as its name; children compose.
        let full = (parent >= 0 ? (dirPath[parent].map { $0 + "/" + name }) : name) ?? name
        dirPath[idx] = full
        pathToDir[full] = idx
        return idx
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
        for i in nodes.indices {
            nodes[i].totalSize = nodes[i].deleted ? 0 : nodes[i].ownSize
            nodes[i].subtreeFiles = 0
            nodes[i].subtreeItems = 0
        }
        var i = nodes.count - 1
        while i > 0 {
            if !nodes[i].deleted {
                let p = Int(nodes[i].parent)
                if p >= 0 {
                    nodes[p].totalSize += nodes[i].totalSize
                    nodes[p].subtreeItems += 1 + nodes[i].subtreeItems
                    nodes[p].subtreeFiles += (nodes[i].isDir ? 0 : 1) + nodes[i].subtreeFiles
                }
            }
            i -= 1
        }
    }

    /// Immediate (live) children of a node, as index values (for treemap drill-down).
    public func children(of index: Int) -> [Int] {
        var out: [Int] = []
        var c = nodes[index].firstChild
        while c >= 0 {
            let i = Int(c)
            if !nodes[i].deleted { out.append(i) }
            c = nodes[i].nextSibling
        }
        return out
    }

    // MARK: - Live reconcile (Phase 1 — FSEvents patch target)

    /// Re-scan one directory level and patch the index to match: add new entries
    /// (grafting whole subtrees for new directories), tombstone vanished ones, update
    /// changed file sizes. This is the deterministic unit FSEvents triggers. Idempotent:
    /// reconciling an unchanged directory is a no-op. Re-run aggregate() afterward to
    /// refresh treemap totals.
    @discardableResult
    public func reconcile(directoryPath: String) -> ReconcileDelta {
        guard let dnode = pathToDir[directoryPath] else { return ReconcileDelta() }

        guard let fresh = DiskScopeScanner.scanLevel(path: directoryPath) else {
            // The directory itself is gone — tombstone it (its parent's reconcile will
            // also unlink it, but doing it here keeps a direct event correct).
            tombstone(dnode)
            return ReconcileDelta(added: 0, removed: 1, updated: 0)
        }

        // Live children by name.
        var existing: [String: Int] = [:]
        for i in children(of: dnode) { existing[nodes[i].name] = i }

        var delta = ReconcileDelta()
        var seen = Set<String>()
        for e in fresh {
            seen.insert(e.name)
            if let i = existing[e.name] {
                if nodes[i].isDir == e.isDir {
                    if !e.isDir && nodes[i].ownSize != e.allocSize {
                        nodes[i].ownSize = e.allocSize
                        delta.updated += 1
                    }
                } else {
                    // A name flipped file<->dir: remove the old, add the new.
                    tombstone(i); delta.removed += 1
                    addEntry(e, parent: dnode, parentPath: directoryPath, delta: &delta)
                }
            } else {
                addEntry(e, parent: dnode, parentPath: directoryPath, delta: &delta)
            }
        }
        for (name, i) in existing where !seen.contains(name) {
            tombstone(i); delta.removed += 1
        }
        return delta
    }

    private func addEntry(_ e: DiskScopeScanner.Entry, parent: Int, parentPath: String, delta: inout ReconcileDelta) {
        if e.isDir {
            // Graft the whole new subtree under `parent`.
            DiskScopeScanner.scanSubtree(path: parentPath + "/" + e.name, parent: parent, into: self)
        } else {
            file(parent: parent, name: e.name, allocSize: e.allocSize)
        }
        delta.added += 1
    }

    /// Mark a node (and its subtree) deleted, and drop its directory path mappings so a
    /// later re-create re-indexes cleanly. We tombstone rather than unlink to keep the
    /// arena's parent-before-child ordering intact for aggregate().
    private func tombstone(_ index: Int) {
        if nodes[index].deleted { return }
        nodes[index].deleted = true
        if let p = dirPath[index] {
            pathToDir.removeValue(forKey: p)
            dirPath.removeValue(forKey: index)
        }
        var c = nodes[index].firstChild
        while c >= 0 {
            let next = nodes[Int(c)].nextSibling
            tombstone(Int(c))
            c = next
        }
    }

    // MARK: - Search (v1.0)

    /// Case-insensitive substring match over every name. Linear scan — the deliberate
    /// v1 baseline to measure before optimizing.
    public func search(_ query: String, limit: Int = 1000) -> [SearchResult] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var out: [SearchResult] = []
        for i in nodes.indices {
            if !nodes[i].deleted, nodes[i].name.lowercased().contains(needle) {
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
