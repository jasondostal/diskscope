import Darwin

/// A consumer of scan events. The scanner stays generic; the index, a tally, a treemap
/// builder, etc. are all just sinks. `directory` returns an opaque token (the sink's own
/// id for that dir) which the scanner threads back as `parent` for that dir's children —
/// so the sink can rebuild the tree without the scanner knowing anything about trees.
public protocol ScanSink: AnyObject {
    func directory(parent: Int, name: String, allocSize: UInt64) -> Int
    func file(parent: Int, name: String, allocSize: UInt64)
    func unreadable()
}

/// Aggregate tally — the simplest sink, and the Phase 0 CLI's. Also our regression
/// anchor: its counts are cross-checked against `find`.
public final class TallySink: ScanSink {
    public var stats = ScanStats()
    public init() {}
    public func directory(parent: Int, name: String, allocSize: UInt64) -> Int {
        stats.dirs += 1; stats.allocBytes += allocSize; return 0
    }
    public func file(parent: Int, name: String, allocSize: UInt64) {
        stats.files += 1; stats.allocBytes += allocSize
    }
    public func unreadable() { stats.errors += 1 }
}

/// Aggregate result of a scan.
public struct ScanStats: Sendable {
    public var files: Int = 0
    public var dirs: Int = 0
    /// Sum of on-disk allocated size (block-rounded) — the number a treemap should show.
    public var allocBytes: UInt64 = 0
    /// Directories we couldn't open (SIP / no Full Disk Access / races). Skipped silently.
    public var errors: Int = 0
    public init() {}
}

/// Fast recursive directory walk via getattrlistbulk(2): one syscall returns many
/// entries' name+type+size at once, far cheaper than readdir + per-file stat.
/// Single-threaded; fd usage is bounded by tree DEPTH, not breadth (we descend one
/// directory at a time after draining the current level).
public enum DiskScopeScanner {

    private static let bufferSize = 256 * 1024

    // fsobj_type_t values (sys/vnode.h). getattrlistbulk does NOT emit "." or "..".
    private static let VDIR: UInt32 = 2

    /// Convenience tally scan (CLI + `find` cross-check).
    public static func scan(path: String) -> ScanStats {
        let sink = TallySink()
        // The root itself isn't an "entry" of anything; count it as a directory.
        _ = sink.directory(parent: -1, name: path, allocSize: 0)
        scanRoot(path: path, rootToken: 0, into: sink)
        return sink.stats
    }

    /// Indexing scan: drive an arbitrary sink. The sink assigns the root its own token.
    public static func scan(path: String, into sink: ScanSink) {
        let rootToken = sink.directory(parent: -1, name: path, allocSize: 0)
        scanRoot(path: path, rootToken: rootToken, into: sink)
    }

    /// Graft a subtree under an existing parent token (the subtree root is named by its
    /// basename, not full path). Used by live reconcile when a new directory appears.
    public static func scanSubtree(path: String, parent: Int, into sink: ScanSink) {
        let base = String(path.split(separator: "/").last ?? Substring(path))
        let rootToken = sink.directory(parent: parent, name: base, allocSize: 0)
        scanRoot(path: path, rootToken: rootToken, into: sink)
    }

    /// One entry in a single directory level (no recursion).
    public struct Entry: Sendable {
        public let name: String
        public let isDir: Bool
        public let allocSize: UInt64
    }

    /// Scan exactly one directory level — the primitive for reconcile() diffing.
    /// Returns nil if the directory can't be opened (deleted / unreadable).
    public static func scanLevel(path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 { return nil }
        defer { close(fd) }

        let bitReturned = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        let bitName = UInt32(truncatingIfNeeded: ATTR_CMN_NAME)
        let bitObjType = UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let bitAlloc = UInt32(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = bitReturned | bitName | bitObjType
        attrList.fileattr = bitAlloc

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }

        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &attrList, buf, bufferSize, 0)
            if count <= 0 { break }
            var entry = buf
            for _ in 0..<count {
                let len = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                var cursor = 4
                let returnedCommon = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                let returnedFile = entry.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self)
                cursor += 20
                var name = ""
                var objType: UInt32 = 0
                var allocSize: UInt64 = 0
                if returnedCommon & bitName != 0 {
                    let nameOffset = entry.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
                    let namePtr = entry.advanced(by: cursor + Int(nameOffset))
                    name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                    cursor += 8
                }
                if returnedCommon & bitObjType != 0 {
                    objType = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                    cursor += 4
                }
                if returnedFile & bitAlloc != 0 {
                    let alloc = entry.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                    allocSize = UInt64(max(0, alloc))
                    cursor += 8
                }
                entries.append(Entry(name: name, isDir: objType == VDIR, allocSize: allocSize))
                entry = entry.advanced(by: Int(len))
            }
        }
        return entries
    }

    private static func scanRoot(path: String, rootToken: Int, into sink: ScanSink) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 { sink.unreadable(); return }
        scanDir(fd: fd, parent: rootToken, into: sink)
        close(fd)
    }

    private static func scanDir(fd: Int32, parent: Int, into sink: ScanSink) {
        // C constants import with mixed signedness; normalize to UInt32 before OR-ing.
        let bitReturned = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        let bitName = UInt32(truncatingIfNeeded: ATTR_CMN_NAME)
        let bitObjType = UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let bitAlloc = UInt32(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = bitReturned | bitName | bitObjType
        attrList.fileattr = bitAlloc

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }

        // (childName, childToken) pairs to descend into after draining this level.
        var childDirs: [(name: String, token: Int)] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buf, bufferSize, 0)
            if count <= 0 {
                if count < 0 { sink.unreadable() }
                break
            }

            var entry = buf
            for _ in 0..<count {
                let len = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                var cursor = 4

                // attribute_set_t returned = 5 x u_int32 (common, vol, dir, file, fork).
                let returnedCommon = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                let returnedFile = entry.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self)
                cursor += 20

                var name = ""
                var objType: UInt32 = 0
                var allocSize: UInt64 = 0

                if returnedCommon & bitName != 0 {
                    // attrreference_t { int32 dataoffset; uint32 length } — name bytes live
                    // at (this attrreference's address + dataoffset).
                    let nameOffset = entry.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
                    let namePtr = entry.advanced(by: cursor + Int(nameOffset))
                    name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                    cursor += 8
                }
                if returnedCommon & bitObjType != 0 {
                    objType = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                    cursor += 4
                }
                if returnedFile & bitAlloc != 0 {
                    let alloc = entry.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                    allocSize = UInt64(max(0, alloc))
                    cursor += 8
                }

                if objType == VDIR {
                    let token = sink.directory(parent: parent, name: name, allocSize: allocSize)
                    childDirs.append((name, token))
                } else {
                    sink.file(parent: parent, name: name, allocSize: allocSize)
                }

                entry = entry.advanced(by: Int(len))
            }
        }

        for (name, token) in childDirs {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if child >= 0 {
                scanDir(fd: child, parent: token, into: sink)
                close(child)
            } else {
                sink.unreadable()
            }
        }
    }
}
