import Darwin

/// Aggregate result of a scan. Phase 0 cares about count + bytes + wall-clock;
/// the real index (Phase 1) will retain per-entry records instead of just tallies.
public struct ScanStats: Sendable {
    public var files: Int = 0
    public var dirs: Int = 0
    /// Sum of on-disk allocated size (block-rounded), the number a treemap should show.
    public var allocBytes: UInt64 = 0
    /// Directories we couldn't open (SIP / no Full Disk Access / races). Skipped silently.
    public var errors: Int = 0

    public init() {}
}

/// Fast recursive directory walk using getattrlistbulk(2) — one syscall returns
/// many entries' name+type+size at once, far cheaper than readdir + per-file stat.
///
/// Single-threaded baseline. We measure this BEFORE parallelizing (handoff: measure
/// before optimizing). fd usage is bounded by tree DEPTH, not breadth: we collect
/// child directory names while draining a dir, then descend one at a time.
public enum DiskScopeScanner {

    /// Bigger buffer = fewer syscalls. 256 KiB holds a lot of entries per call.
    private static let bufferSize = 256 * 1024

    // fsobj_type_t values (sys/vnode.h). getattrlistbulk does NOT emit "." or "..".
    private static let VREG: UInt32 = 1
    private static let VDIR: UInt32 = 2

    public static func scan(path: String) -> ScanStats {
        var stats = ScanStats()
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 { stats.errors += 1; return stats }
        scanDir(fd: fd, into: &stats)
        close(fd)
        return stats
    }

    private static func scanDir(fd: Int32, into stats: inout ScanStats) {
        // The C constants import with mixed signedness (RETURNED_ATTRS is UInt32,
        // the rest Int32), so normalize each to UInt32 before OR-ing.
        let bitReturned = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        let bitName = UInt32(truncatingIfNeeded: ATTR_CMN_NAME)
        let bitObjType = UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let bitAlloc = UInt32(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

        // Request, in bitmap order: RETURNED_ATTRS (always first), NAME, OBJTYPE,
        // and for files ALLOCSIZE. Keep it minimal — every extra attr is more parsing.
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = bitReturned | bitName | bitObjType
        attrList.fileattr = bitAlloc

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }

        var childNames: [String] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buf, bufferSize, 0)
            if count <= 0 {
                if count < 0 { stats.errors += 1 }
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

                // The name's attrreference_t is a fixed 8 bytes here; the variable-length
                // name bytes live elsewhere (at attrreference + dataoffset). So we can read
                // objtype FIRST and only materialize the String for directories — files
                // (the ~90% bulk) never pay a heap allocation.
                var nameFieldCursor = -1
                var objType: UInt32 = 0

                if returnedCommon & bitName != 0 {
                    nameFieldCursor = cursor
                    cursor += 8 // sizeof(attrreference_t)
                }
                if returnedCommon & bitObjType != 0 {
                    objType = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                    cursor += 4
                }
                if returnedFile & bitAlloc != 0 {
                    let alloc = entry.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                    stats.allocBytes += UInt64(max(0, alloc))
                    cursor += 8
                }

                if objType == VDIR {
                    stats.dirs += 1
                    if nameFieldCursor >= 0 {
                        let nameOffset = entry.loadUnaligned(fromByteOffset: nameFieldCursor, as: Int32.self)
                        let namePtr = entry.advanced(by: nameFieldCursor + Int(nameOffset))
                        childNames.append(String(cString: namePtr.assumingMemoryBound(to: CChar.self)))
                    }
                } else {
                    stats.files += 1
                }

                entry = entry.advanced(by: Int(len))
            }
        }

        // Descend depth-first, one fd at a time (bounds open fds to tree depth).
        for name in childNames {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if child >= 0 {
                scanDir(fd: child, into: &stats)
                close(child)
            } else {
                stats.errors += 1
            }
        }
    }
}
