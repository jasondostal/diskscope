import Foundation

/// Persistent snapshot of a FileIndex — the half of "incremental indexing" that lives on
/// disk. Saved with the FSEvents event ID captured when the index was last known current;
/// WarmStart loads it and replays only the journal since that ID, so a relaunch costs
/// milliseconds instead of a full-volume walk.
///
/// Format (v1, little-endian, columnar — mirrors the arena so save/load is a few big
/// memcpy-shaped passes, not per-node encoding):
///   u32 magic "DSIX" · u32 version · u64 eventID · u32 unreadable
///   u32 rootLen · root UTF-8
///   u64 nodeCount
///   [i32 parent]×n · [i32 firstChild]×n · [i32 nextSibling]×n
///   [u64 ownSize]×n · [i64 modTime]×n · [i64 createTime]×n · [u8 flags]×n
///   [u16 nameLen]×n · name blob (UTF-8, concatenated)
/// totalSize/subtree counts are NOT stored — aggregate() after load is one cheap pass.
public enum IndexStore {

    private static let magic: UInt32 = 0x4453_4958 // "DSIX"
    private static let version: UInt32 = 1

    /// ~/Library/Application Support/DiskScope (shared by the GUI and the TUI — a scan
    /// from either warms the other).
    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("DiskScope", isDirectory: true)
    }

    public static func url(forRoot root: String) -> URL {
        directory().appendingPathComponent("index-\(fnv1a(root)).dsix")
    }

    /// FNV-1a 64 of the root path — a stable filename key, no crypto dependency needed.
    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", h)
    }

    // MARK: - Save

    public static func save(_ index: FileIndex, root: String, eventID: UInt64) throws {
        let nodes = index.nodes
        let n = nodes.count
        var data = Data()
        data.reserveCapacity(64 + root.utf8.count + n * 45)

        func put<T>(_ v: T) {
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
        func putColumn<T>(_ col: [T]) {
            col.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        }

        put(magic); put(version); put(eventID); put(UInt32(index.unreadableCount))
        let rootBytes = Array(root.utf8)
        put(UInt32(rootBytes.count)); data.append(contentsOf: rootBytes)
        put(UInt64(n))

        putColumn(nodes.map(\.parent))
        putColumn(nodes.map(\.firstChild))
        putColumn(nodes.map(\.nextSibling))
        putColumn(nodes.map(\.ownSize))
        putColumn(nodes.map(\.modTime))
        putColumn(nodes.map(\.createTime))
        putColumn(nodes.map { ($0.isDir ? UInt8(1) : 0) | ($0.deleted ? 2 : 0) })

        var blob = Data()
        var nameLens = [UInt16](); nameLens.reserveCapacity(n)
        for node in nodes {
            let u = Array(node.name.utf8)
            nameLens.append(UInt16(min(u.count, Int(UInt16.max))))
            blob.append(contentsOf: u.prefix(Int(UInt16.max)))
        }
        putColumn(nameLens)
        data.append(blob)

        try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        try data.write(to: url(forRoot: root), options: .atomic)
    }

    // MARK: - Load

    public static func load(root: String) -> (index: FileIndex, eventID: UInt64)? {
        guard let data = try? Data(contentsOf: url(forRoot: root), options: .mappedIfSafe) else { return nil }
        var off = 0

        func take<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard off + size <= data.count else { return nil }
            defer { off += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) }
        }
        func takeColumn<T>(_ type: T.Type, count: Int) -> [T]? {
            let size = MemoryLayout<T>.stride * count
            guard off + size <= data.count else { return nil }
            defer { off += size }
            return data.withUnsafeBytes { raw in
                [T](unsafeUninitializedCapacity: count) { dst, initialized in
                    raw.copyBytes(to: UnsafeMutableRawBufferPointer(dst), from: off..<(off + size))
                    initialized = count
                }
            }
        }

        guard take(UInt32.self) == magic, take(UInt32.self) == version,
              let eventID = take(UInt64.self),
              let unreadable = take(UInt32.self),
              let rootLen = take(UInt32.self), off + Int(rootLen) <= data.count
        else { return nil }
        let storedRoot = String(decoding: data[off..<(off + Int(rootLen))], as: UTF8.self)
        off += Int(rootLen)
        guard storedRoot == root, let count64 = take(UInt64.self) else { return nil }
        let n = Int(count64)
        guard n > 0, n < 500_000_000 else { return nil }

        guard let parents = takeColumn(Int32.self, count: n),
              let firstChildren = takeColumn(Int32.self, count: n),
              let nextSiblings = takeColumn(Int32.self, count: n),
              let ownSizes = takeColumn(UInt64.self, count: n),
              let modTimes = takeColumn(Int64.self, count: n),
              let createTimes = takeColumn(Int64.self, count: n),
              let flags = takeColumn(UInt8.self, count: n),
              let nameLens = takeColumn(UInt16.self, count: n)
        else { return nil }

        let blobLen = nameLens.reduce(0) { $0 + Int($1) }
        guard off + blobLen <= data.count else { return nil }

        var nodes = [IndexNode]()
        nodes.reserveCapacity(n)
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var nameOff = off
            for i in 0..<n {
                let len = Int(nameLens[i])
                let name = String(decoding: raw[nameOff..<(nameOff + len)], as: UTF8.self)
                nameOff += len
                var node = IndexNode(name: name, parent: parents[i],
                                     ownSize: ownSizes[i], isDir: flags[i] & 1 != 0)
                node.firstChild = firstChildren[i]
                node.nextSibling = nextSiblings[i]
                node.deleted = flags[i] & 2 != 0
                node.modTime = modTimes[i]
                node.createTime = createTimes[i]
                if node.parent >= Int32(i) { ok = false; return } // arena invariant broken
                nodes.append(node)
            }
        }
        guard ok, nodes.count == n else { return nil }
        return (FileIndex(restoring: nodes, unreadableCount: Int(unreadable)), eventID)
    }
}
