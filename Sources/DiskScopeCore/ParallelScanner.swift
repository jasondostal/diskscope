import Darwin
import Foundation

/// Parallel directory scan: a fixed worker pool drains a shared queue of directory
/// paths. Each worker scans ONE directory level (one openat + getattrlistbulk loop),
/// pushes child directories back onto the queue, and accumulates into a thread-local
/// tally that's merged once at exit. The queue holds paths, not fds, so we never hoard
/// open descriptors across the frontier (which would blow RLIMIT_NOFILE on a wide tree).
///
/// The question this answers: does APFS metadata read scale across cores, or do the
/// kernel's VFS/B-tree locks serialize us back to the single-threaded floor?
public final class DiskScopeParallelScanner {

    private static let bufferSize = 256 * 1024
    private static let VDIR: UInt32 = 2

    private let cond = NSCondition()
    private var pending: [String]
    private var active = 0          // directories handed out but not yet finished
    private var total = ScanStats() // merged under `cond`

    private init(root: String) { pending = [root] }

    public static func scan(path: String, workers: Int) -> ScanStats {
        let pool = DiskScopeParallelScanner(root: path)
        let group = DispatchGroup()
        for _ in 0..<max(1, workers) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                pool.workerLoop()
            }
        }
        group.wait()
        return pool.total
    }

    private func workerLoop() {
        var local = ScanStats()
        while true {
            cond.lock()
            while pending.isEmpty && active > 0 { cond.wait() }
            if pending.isEmpty && active == 0 {
                cond.broadcast()        // wake peers so they also observe termination
                cond.unlock()
                break
            }
            let path = pending.removeLast()
            active += 1
            cond.unlock()

            var children: [String] = []
            scanLevel(path: path, into: &local, children: &children)

            cond.lock()
            pending.append(contentsOf: children)
            active -= 1
            cond.broadcast()            // new work and/or possible termination
            cond.unlock()
        }

        cond.lock()
        total.files += local.files
        total.dirs += local.dirs
        total.allocBytes += local.allocBytes
        total.errors += local.errors
        cond.unlock()
    }

    /// Scan a single directory (no recursion). Mirrors the serial scanner's buffer
    /// parse, but emits child directory PATHS instead of descending inline.
    private func scanLevel(path: String, into stats: inout ScanStats, children: inout [String]) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 { stats.errors += 1; return }
        defer { close(fd) }

        let bitReturned = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        let bitName = UInt32(truncatingIfNeeded: ATTR_CMN_NAME)
        let bitObjType = UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        let bitAlloc = UInt32(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = bitReturned | bitName | bitObjType
        attrList.fileattr = bitAlloc

        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buf.deallocate() }

        let prefix = path == "/" ? "/" : path + "/"

        while true {
            let count = getattrlistbulk(fd, &attrList, buf, Self.bufferSize, 0)
            if count <= 0 {
                // ERANGE after an exact fill = complete, not an error (APFS quirk).
                if count < 0 && errno != ERANGE { stats.errors += 1 }
                break
            }
            var entry = buf
            for _ in 0..<count {
                let len = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                var cursor = 4
                let returnedCommon = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                let returnedFile = entry.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self)
                cursor += 20

                var nameFieldCursor = -1
                var objType: UInt32 = 0

                if returnedCommon & bitName != 0 { nameFieldCursor = cursor; cursor += 8 }
                if returnedCommon & bitObjType != 0 {
                    objType = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                    cursor += 4
                }
                if returnedFile & bitAlloc != 0 {
                    let alloc = entry.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                    stats.allocBytes += UInt64(max(0, alloc))
                    cursor += 8
                }

                if objType == Self.VDIR {
                    stats.dirs += 1
                    if nameFieldCursor >= 0 {
                        let nameOffset = entry.loadUnaligned(fromByteOffset: nameFieldCursor, as: Int32.self)
                        let namePtr = entry.advanced(by: nameFieldCursor + Int(nameOffset))
                        children.append(prefix + String(cString: namePtr.assumingMemoryBound(to: CChar.self)))
                    }
                } else {
                    stats.files += 1
                }

                entry = entry.advanced(by: Int(len))
            }
        }
    }
}
