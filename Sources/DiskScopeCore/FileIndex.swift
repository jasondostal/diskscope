import Foundation
import Darwin

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
    // Timestamps in epoch seconds; 0 = unknown (root / grafted subtree roots).
    public var modTime: Int64 = 0      // last content modification (WinDirStat's "Last Change")
    public var createTime: Int64 = 0   // creation / birth time
}

/// What a single reconcile changed — for logging / Live-Wire UI deltas.
///
/// Beyond the entry counts, it carries the NET size/count change so callers (and the index
/// itself) can patch aggregates incrementally instead of re-running a full O(n) aggregate():
/// `bytes`/`files`/`items` are applied to the reconciled directory's ancestor chain by
/// reconcile() itself, and `extBytes` lets a UI legend update without a full rebuild.
public struct ReconcileDelta: Sendable, Equatable {
    public var added = 0
    public var removed = 0
    public var updated = 0
    /// Net allocated-byte change under the reconciled directory.
    public var bytes: Int64 = 0
    /// Net file-count / item-count change under the reconciled directory.
    public var files = 0
    public var items = 0
    /// Net byte / file-count change per extension ("" = no extension) — feeds incremental legends.
    public var extBytes: [String: Int64] = [:]
    public var extCounts: [String: Int] = [:]
    public init(added: Int = 0, removed: Int = 0, updated: Int = 0) {
        self.added = added; self.removed = removed; self.updated = updated
    }
    public var changed: Bool { added + removed + updated > 0 }

    mutating func addFile(name: String, size: UInt64) {
        bytes += Int64(size); files += 1
        let e = FileIndex.ext(of: name)
        extBytes[e, default: 0] += Int64(size)
        extCounts[e, default: 0] += 1
    }
    mutating func removeFile(name: String, size: UInt64) {
        bytes -= Int64(size); files -= 1
        let e = FileIndex.ext(of: name)
        extBytes[e, default: 0] -= Int64(size)
        extCounts[e, default: 0] -= 1
    }
    mutating func resizeFile(name: String, from old: UInt64, to new: UInt64) {
        let d = Int64(new) - Int64(old)
        bytes += d
        extBytes[FileIndex.ext(of: name), default: 0] += d
    }
}

public struct SearchResult {
    public let node: Int
    public let name: String
    public let path: String
    public let size: UInt64
    public let isDir: Bool
    /// Match quality: 0 prefix · 1 word-start · 2 mid-word · 3 filter-only. Exposed so a
    /// multi-volume merge can re-rank across indexes without re-deriving it.
    public let rank: UInt8
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

    // Search blob: every node's lowercased name, concatenated into ONE contiguous UTF-8
    // buffer with '/' separators ('/' cannot occur inside a POSIX filename, so a needle
    // without '/' can never match across a name boundary). memmem(3) scans this at memory
    // bandwidth — single-digit milliseconds for any substring over a million names. Same
    // brute force Everything uses: at this scale, brute force beats clever.
    private var nameBlob: [UInt8] = []
    private var nameStart: [UInt32] = []   // per-node start offset into nameBlob

    private func appendSearchName(_ name: String) {
        nameStart.append(UInt32(nameBlob.count))
        nameBlob.append(contentsOf: name.lowercased().utf8)
        nameBlob.append(0x2F) // '/'
    }

    public init() {}

    /// Rebuild a previously serialized index (IndexStore). Parents precede children in the
    /// arena, so the path maps and lowercase blob rebuild in one forward pass.
    public convenience init(restoring nodes: [IndexNode], unreadableCount: Int) {
        self.init()
        self.nodes = nodes
        self.unreadableCount = unreadableCount
        nameStart.reserveCapacity(nodes.count)
        for i in nodes.indices {
            appendSearchName(nodes[i].name)
            if nodes[i].isDir && !nodes[i].deleted {
                let p = Int(nodes[i].parent)
                // A live node's ancestors are live (tombstoning marks whole subtrees), so
                // the parent's path is always present by the time we reach the child.
                let full = p >= 0 ? (dirPath[p].map { $0 + "/" + nodes[i].name } ?? nodes[i].name)
                                  : nodes[i].name
                dirPath[i] = full
                pathToDir[full] = i
            }
        }
    }

    /// Extension (lowercased, no dot) of a filename, or "" if none.
    public static func ext(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    public var count: Int { nodes.lazy.filter { !$0.deleted }.count }
    public var fileCount: Int { nodes.lazy.filter { !$0.isDir && !$0.deleted }.count }
    public var dirCount: Int { nodes.lazy.filter { $0.isDir && !$0.deleted }.count }

    // MARK: - ScanSink (build path)

    public func directory(parent: Int, name: String, allocSize: UInt64, modTime: Int64, createTime: Int64) -> Int {
        var node = IndexNode(name: name, parent: Int32(parent), ownSize: 0, isDir: true)
        node.modTime = modTime; node.createTime = createTime
        let idx = append(node, parent: parent)
        // Root (parent -1) carries the full scanned path as its name; children compose.
        let full = (parent >= 0 ? (dirPath[parent].map { $0 + "/" + name }) : name) ?? name
        dirPath[idx] = full
        pathToDir[full] = idx
        return idx
    }

    public func file(parent: Int, name: String, allocSize: UInt64, modTime: Int64, createTime: Int64) {
        var node = IndexNode(name: name, parent: Int32(parent), ownSize: allocSize, isDir: false)
        node.modTime = modTime; node.createTime = createTime
        _ = append(node, parent: parent)
    }

    public func unreadable() { unreadableCount += 1 }

    @discardableResult
    private func append(_ node: IndexNode, parent: Int) -> Int {
        let idx = nodes.count
        nodes.append(node)
        appendSearchName(node.name)
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
    /// reconciling an unchanged directory is a no-op.
    ///
    /// Aggregates stay coherent WITHOUT a full aggregate(): the computed delta is applied
    /// to the directory's ancestor chain in O(depth). (Assumes aggregate() ran once after
    /// the initial build — every build path does.)
    @discardableResult
    public func reconcile(directoryPath: String) -> ReconcileDelta {
        guard let dnode = pathToDir[directoryPath] else { return ReconcileDelta() }

        guard let fresh = DiskScopeScanner.scanLevel(path: directoryPath) else {
            // The directory itself is gone — tombstone it (its parent's reconcile will
            // also unlink it, but doing it here keeps a direct event correct).
            var delta = ReconcileDelta(removed: 1)
            let parent = Int(nodes[dnode].parent)
            delta.items -= 1 // the directory entry itself, from its parent's perspective
            tombstone(dnode, into: &delta)
            applyDelta(delta, startingAt: parent)
            return delta
        }

        // Live children by name.
        var existing: [String: Int] = [:]
        for i in children(of: dnode) { existing[nodes[i].name] = i }

        var delta = ReconcileDelta()
        var seen = Set<String>()
        for e in fresh.entries {
            seen.insert(e.name)
            if let i = existing[e.name] {
                if nodes[i].isDir == e.isDir {
                    if !e.isDir && (nodes[i].ownSize != e.allocSize || nodes[i].modTime != e.modTime) {
                        delta.resizeFile(name: e.name, from: nodes[i].ownSize, to: e.allocSize)
                        nodes[i].ownSize = e.allocSize
                        nodes[i].totalSize = e.allocSize // files: totalSize mirrors ownSize
                        nodes[i].modTime = e.modTime
                        nodes[i].createTime = e.createTime
                        delta.updated += 1
                    }
                } else {
                    // A name flipped file<->dir: remove the old, add the new.
                    removeEntry(i, delta: &delta)
                    addEntry(e, parent: dnode, parentPath: directoryPath, delta: &delta)
                }
            } else {
                addEntry(e, parent: dnode, parentPath: directoryPath, delta: &delta)
            }
        }
        for (name, i) in existing where !seen.contains(name) {
            removeEntry(i, delta: &delta)
        }
        applyDelta(delta, startingAt: dnode)
        return delta
    }

    /// Subtree-granular reconcile, for FSEvents "must scan subdirs" flags: tombstone the
    /// stale subtree and re-graft it fresh from disk. Returns an empty delta for the root
    /// (callers should full-rescan) or an unknown path.
    @discardableResult
    public func reconcileSubtree(directoryPath: String) -> ReconcileDelta {
        guard let n = pathToDir[directoryPath], n != 0 else { return ReconcileDelta() }
        let parent = Int(nodes[n].parent)
        var delta = ReconcileDelta(added: 1, removed: 1)
        delta.items -= 1
        tombstone(n, into: &delta)
        let before = nodes.count
        DiskScopeScanner.scanSubtree(path: directoryPath, parent: parent, into: self)
        tallyAppended(from: before, into: &delta)
        applyDelta(delta, startingAt: parent)
        return delta
    }

    private func addEntry(_ e: DiskScopeScanner.Entry, parent: Int, parentPath: String, delta: inout ReconcileDelta) {
        let before = nodes.count
        if e.isDir {
            // Graft the whole new subtree under `parent`.
            DiskScopeScanner.scanSubtree(path: parentPath + "/" + e.name, parent: parent, into: self)
        } else {
            file(parent: parent, name: e.name, allocSize: e.allocSize, modTime: e.modTime, createTime: e.createTime)
        }
        tallyAppended(from: before, into: &delta)
        delta.added += 1
    }

    /// Tombstone an entry and fold its subtree's bytes/counts out of the delta.
    private func removeEntry(_ i: Int, delta: inout ReconcileDelta) {
        delta.items -= 1
        tombstone(i, into: &delta)
        delta.removed += 1
    }

    /// Fold every node appended since `start` (a fresh graft) into the delta — each node is
    /// one item; files additionally carry bytes/files/ext — AND aggregate the appended range
    /// in place (a graft arrives with zeroed totals; ancestors get the delta separately, but
    /// the new nodes need their own subtree sums or the treemap sees empty folders).
    private func tallyAppended(from start: Int, into delta: inout ReconcileDelta) {
        for j in start..<nodes.count {
            delta.items += 1
            nodes[j].totalSize = nodes[j].ownSize
            nodes[j].subtreeFiles = 0
            nodes[j].subtreeItems = 0
            if !nodes[j].isDir {
                delta.addFile(name: nodes[j].name, size: nodes[j].ownSize)
            }
        }
        // Roll up within the appended range (parents precede children; the graft's parent
        // sits below `start` and is covered by applyDelta).
        var i = nodes.count - 1
        while i > start {
            let p = Int(nodes[i].parent)
            if p >= start {
                nodes[p].totalSize += nodes[i].totalSize
                nodes[p].subtreeItems += 1 + nodes[i].subtreeItems
                nodes[p].subtreeFiles += (nodes[i].isDir ? 0 : 1) + nodes[i].subtreeFiles
            }
            i -= 1
        }
    }

    /// Patch totalSize/subtreeFiles/subtreeItems up the ancestor chain — O(depth), the
    /// incremental replacement for a full aggregate() after a reconcile.
    private func applyDelta(_ d: ReconcileDelta, startingAt node: Int) {
        guard d.bytes != 0 || d.files != 0 || d.items != 0 else { return }
        var i = node
        while i >= 0 {
            nodes[i].totalSize = UInt64(max(0, Int64(nodes[i].totalSize) + d.bytes))
            nodes[i].subtreeFiles = max(0, nodes[i].subtreeFiles + Int32(d.files))
            nodes[i].subtreeItems = max(0, nodes[i].subtreeItems + Int32(d.items))
            i = Int(nodes[i].parent)
        }
    }

    /// Mark a node (and its subtree) deleted, fold the removed bytes/counts into `delta`,
    /// and drop its directory path mappings so a later re-create re-indexes cleanly. We
    /// tombstone rather than unlink to keep the arena's parent-before-child ordering
    /// intact for aggregate().
    private func tombstone(_ index: Int, into delta: inout ReconcileDelta) {
        if nodes[index].deleted { return }
        nodes[index].deleted = true
        if !nodes[index].isDir {
            delta.removeFile(name: nodes[index].name, size: nodes[index].ownSize)
        }
        if let p = dirPath[index] {
            pathToDir.removeValue(forKey: p)
            dirPath.removeValue(forKey: index)
        }
        var c = nodes[index].firstChild
        while c >= 0 {
            let next = nodes[Int(c)].nextSibling
            delta.items -= 1
            tombstone(Int(c), into: &delta)
            c = next
        }
    }

    // MARK: - Search (v1.0)

    /// Everything-style search: parse the raw query (bare tokens AND-match the name;
    /// `ext:` `size:` `kind:` `path:` filter — see SearchQuery), sweep the contiguous name
    /// blob with one memmem(3) pass (~ms per keystroke on a million names), then rank —
    /// prefix beats word-start beats mid-word, ties broken by size descending (this is a
    /// disk tool: the biggest match is almost always the one you want).
    public func search(_ raw: String, limit: Int = 1000) -> [SearchResult] {
        search(SearchQuery.parse(raw), limit: limit)
    }

    public func search(_ q: SearchQuery, limit: Int = 1000) -> [SearchResult] {
        guard !q.isEmpty, !q.impossible else { return [] }

        struct Hit { let node: Int; let rank: UInt8; let size: UInt64 }
        var hits: [Hit] = []
        // Bound the raw sweep: a 1-char query can hit most of the index; 50k candidates
        // sort in ~ms and is far more than any UI shows. (Past the cap, results favor
        // arena order — fine for a query that broad.)
        let maxHits = 50_000

        // Cheap predicates inline; the path filter (string-builds per candidate) last.
        func passesFilters(_ node: Int, _ n: IndexNode, _ size: UInt64) -> Bool {
            if let kd = q.kindDir, n.isDir != kd { return false }
            if let mn = q.sizeMin, size < mn { return false }
            if let mx = q.sizeMax, size > mx { return false }
            if let e = q.ext, n.isDir || FileIndex.ext(of: n.name) != e { return false }
            if let p = q.pathNeedle, !path(of: node).lowercased().contains(p) { return false }
            return true
        }

        if let primary = q.primary {
            let secondaries = q.needles.filter { $0 != primary }
            nameBlob.withUnsafeBufferPointer { blob in
                guard let base = blob.baseAddress, !blob.isEmpty else { return }
                primary.withUnsafeBufferPointer { np in
                    var pos = 0
                    while pos < blob.count, hits.count < maxHits {
                        guard let found = memmem(base + pos, blob.count - pos, np.baseAddress!, np.count) else { break }
                        let at = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                        // Which name? Last start <= at (nameStart is ascending).
                        var lo = 0, hi = nameStart.count - 1
                        while lo < hi {
                            let mid = (lo + hi + 1) >> 1
                            if Int(nameStart[mid]) <= at { lo = mid } else { hi = mid - 1 }
                        }
                        let node = lo
                        let start = Int(nameStart[node])
                        let end = node + 1 < nameStart.count ? Int(nameStart[node + 1]) - 1 : nameBlob.count - 1
                        defer { pos = end + 1 } // one hit per name — skip to the next name

                        guard !nodes[node].deleted else { continue }
                        // Remaining needles must ALSO appear somewhere in this name.
                        var allMatch = true
                        for s in secondaries where allMatch {
                            allMatch = s.withUnsafeBufferPointer { sp in
                                memmem(base + start, end - start, sp.baseAddress!, sp.count) != nil
                            }
                        }
                        guard allMatch else { continue }

                        let n = nodes[node]
                        let size = n.isDir ? n.totalSize : n.ownSize
                        guard passesFilters(node, n, size) else { continue }

                        let rank: UInt8
                        if at == start {
                            rank = 0                       // prefix
                        } else {
                            let prev = blob[at - 1]
                            // Word boundary: separator-ish byte before the match.
                            rank = (prev == 0x2E || prev == 0x2D || prev == 0x5F || prev == 0x20
                                    || prev == 0x28 || prev == 0x5B || prev == 0x2B) ? 1 : 2
                        }
                        hits.append(Hit(node: node, rank: rank, size: size))
                    }
                }
            }
        } else {
            // Filter-only query (e.g. "size:>1gb ext:dmg"): one arena walk, cheap checks.
            for i in nodes.indices {
                let n = nodes[i]
                guard !n.deleted else { continue }
                let size = n.isDir ? n.totalSize : n.ownSize
                guard passesFilters(i, n, size) else { continue }
                hits.append(Hit(node: i, rank: 3, size: size))
                if hits.count >= maxHits { break }
            }
        }

        hits.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.size > $1.size }
        return hits.prefix(limit).map { result(for: $0.node, rank: $0.rank) }
    }

    /// Node for an absolute path: directories resolve via the path map; files resolve via
    /// their parent directory + a child-name scan. nil if outside the scan (or deleted).
    public func node(forPath path: String) -> Int? {
        if let d = pathToDir[path] { return d }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let p = pathToDir[parent] else { return nil }
        var c = nodes[p].firstChild
        while c >= 0 {
            let i = Int(c)
            if !nodes[i].deleted, nodes[i].name == name { return i }
            c = nodes[i].nextSibling
        }
        return nil
    }

    /// Total bytes + count of the TOPMOST directories with this exact name — a
    /// node_modules nested inside another node_modules is already inside its ancestor's
    /// totalSize, so counting it again would double-bill. Drives "reclaimable" aggregates.
    public func aggregateDirs(named name: String) -> (bytes: UInt64, count: Int) {
        var bytes: UInt64 = 0
        var count = 0
        outer: for i in nodes.indices where nodes[i].isDir && !nodes[i].deleted && nodes[i].name == name {
            var p = Int(nodes[i].parent)
            while p >= 0 {
                if nodes[p].isDir, !nodes[p].deleted, nodes[p].name == name { continue outer }
                p = Int(nodes[p].parent)
            }
            bytes += nodes[i].totalSize
            count += 1
        }
        return (bytes, count)
    }

    /// Reconstruct an absolute path by walking parent links to the root.
    public func path(of index: Int) -> String {
        var comps: [String] = []
        var cur = index
        while cur > 0 { comps.append(nodes[cur].name); cur = Int(nodes[cur].parent) }
        let base = nodes.isEmpty ? "" : nodes[0].name // root holds the full scanned path
        return comps.isEmpty ? base : base + "/" + comps.reversed().joined(separator: "/")
    }

    private func result(for index: Int, rank: UInt8 = 3) -> SearchResult {
        let n = nodes[index]
        return SearchResult(node: index, name: n.name, path: path(of: index),
                            size: n.isDir ? n.totalSize : n.ownSize, isDir: n.isDir, rank: rank)
    }
}
