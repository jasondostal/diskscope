import Foundation
import DiskScopeCore

/// A directory-tree row backed by a FileIndex node. Children are materialized lazily
/// (and memoized) so the outline only builds the branches you expand — a 50k-node tree
/// stays cheap until you drill in. Sorted largest-first, like WinDirStat.
final class TreeNode: Identifiable {
    let id: Int
    let name: String
    let size: UInt64
    let isDir: Bool

    private let index: FileIndex

    init(id: Int, index: FileIndex) {
        self.id = id
        self.index = index
        let n = index.nodes[id]
        // The root node stores the full scanned path; show its basename in the tree.
        self.name = id == 0 ? (n.name.split(separator: "/").last.map(String.init) ?? n.name) : n.name
        self.isDir = n.isDir
        self.size = n.isDir ? n.totalSize : n.ownSize
    }

    private var memoChildren: [TreeNode]??
    /// nil = a leaf (no disclosure triangle); empty is normalized to nil too.
    var children: [TreeNode]? {
        if let memo = memoChildren { return memo }
        let result: [TreeNode]?
        if isDir {
            let kids = index.children(of: id)
                .sorted { sizeOf($0) > sizeOf($1) }
                .map { TreeNode(id: $0, index: index) }
            result = kids.isEmpty ? nil : kids
        } else {
            result = nil
        }
        memoChildren = .some(result)
        return result
    }

    private func sizeOf(_ i: Int) -> UInt64 {
        let n = index.nodes[i]; return n.isDir ? n.totalSize : n.ownSize
    }
}
