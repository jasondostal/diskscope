import Foundation
import Darwin

private struct DevIno: Hashable { let dev: UInt64; let ino: UInt64 }

/// Builds a FileIndex with a parallel scan: the expensive part (getattrlistbulk syscalls)
/// fans out across worker threads draining a shared work-stealing queue of directory paths;
/// the cheap part (assembling the tree with correct parent links) runs serially afterward
/// from the collected per-directory entry lists.
///
/// Worker count caps at the performance-core count — on Apple Silicon, over-subscribing
/// past the P-cores drags a balanced parallel section toward efficiency-core speed (the
/// 8-worker sweet spot we measured). The queue wakes only as many sleepers as it enqueues
/// (signal, not broadcast) to avoid the lock-convoy collapse.
public enum ParallelIndexBuilder {

    /// Logical performance cores (8 on an M5 Pro), or a sane fallback.
    public static func performanceCoreCount() -> Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// Entries a worker processes inline (openat descent) before spilling child dirs to the
    /// shared queue. Bounds chunk latency so progress/balance stay smooth.
    private static let chunkBudget = 1024
    /// Depth cap on inline descent — bounds per-worker open fds (one per level).
    private static let maxInlineDepth = 48
    /// Mid-chunk spill threshold so idle peers get work before a chunk finishes.
    private static let spillFlush = 64

    /// Scan `root` in parallel and return the assembled, ready-to-aggregate index.
    /// `onProgress(count, bytes)` is called periodically from a worker (off the main thread).
    public static func build(root: String, workers: Int = performanceCoreCount(),
                             onProgress: ((Int, UInt64) -> Void)? = nil) -> FileIndex {
        // Inline descent holds up to maxInlineDepth fds per worker; lift a low soft
        // RLIMIT_NOFILE (CLI default is 256) out of the danger zone.
        var rl = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rl) == 0, rl.rlim_cur < 4096 {
            rl.rlim_cur = min(4096, rl.rlim_max) // rlim_max is huge when "infinity"
            _ = setrlimit(RLIMIT_NOFILE, &rl)
        }
        let shared = Shared(seed: root, onProgress: onProgress)
        let n = max(1, workers)
        let group = DispatchGroup()
        for _ in 0..<n {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                // Encourage the scheduler to keep this worker on a performance core.
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
                workerLoop(shared)
            }
        }
        group.wait()

        // Serial assembly: rebuild the tree from collected (path -> entries), parent before
        // child, into a real FileIndex. Pure in-memory, no syscalls.
        let index = FileIndex()
        // The scanned root has no parent entry to carry its own timestamps; 0 is fine (it's
        // shown as the path basename anyway). Child dirs carry their entry's timestamps down.
        assemble(path: root, name: root, parent: -1, modTime: 0, createTime: 0, dir: shared.byPath, into: index)
        for _ in 0..<shared.errors { index.unreadable() }
        return index
    }

    /// Worker: pop a directory, then descend INLINE via openat (depth-first, one reused
    /// buffer) until the chunk budget is spent — only the overflow goes back to the shared
    /// queue. Compared to one-queue-op-per-directory this kills most of the lock traffic
    /// AND the per-directory full-path open (the kernel re-resolves every component of an
    /// open(path); openat(parentfd, name) resolves one).
    private static func workerLoop(_ shared: Shared) {
        let bufSize = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var local: [(path: String, entries: [DiskScopeScanner.Entry])] = []
        var localErrors = 0

        while let chunkRoot = shared.pop() {
            var spill: [String] = []
            var entriesDone = 0
            var bytes: UInt64 = 0

            func descend(fd: Int32, path: String, depth: Int) {
                guard let level = DiskScopeScanner.scanLevel(fd: fd, buf: buf, bufSize: bufSize) else {
                    localErrors += 1
                    return
                }
                // Dedup by (device, inode): firmlinks (e.g. /Users and /System/Volumes/Data/Users
                // on APFS) and bind mounts expose the same directory under two paths — count once.
                guard shared.firstVisit(dev: level.dev, ino: level.ino) else { return }
                local.append((path, level.entries))
                entriesDone += level.entries.count
                let prefix = path == "/" ? "/" : path + "/"
                for e in level.entries {
                    if e.isDir {
                        if entriesDone >= chunkBudget || depth >= maxInlineDepth {
                            spill.append(prefix + e.name)
                            if spill.count >= spillFlush {
                                shared.push(children: spill)
                                spill.removeAll(keepingCapacity: true)
                            }
                        } else {
                            let cfd = openat(fd, e.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                            if cfd >= 0 {
                                descend(fd: cfd, path: prefix + e.name, depth: depth + 1)
                                close(cfd)
                            } else {
                                localErrors += 1
                            }
                        }
                    } else {
                        bytes += e.allocSize
                    }
                }
            }

            let fd = open(chunkRoot, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                descend(fd: fd, path: chunkRoot, depth: 0)
                close(fd)
            } else {
                localErrors += 1
            }
            shared.complete(children: spill, entries: entriesDone, bytes: bytes)
        }
        shared.merge(local, errors: localErrors)
    }

    private static func assemble(path: String, name: String, parent: Int,
                                 modTime: Int64, createTime: Int64,
                                 dir: [String: [DiskScopeScanner.Entry]], into index: FileIndex) {
        let token = index.directory(parent: parent, name: name, allocSize: 0,
                                    modTime: modTime, createTime: createTime)
        guard let entries = dir[path] else { return }
        let prefix = path == "/" ? "/" : path + "/"
        for e in entries {
            if e.isDir {
                assemble(path: prefix + e.name, name: e.name, parent: token,
                         modTime: e.modTime, createTime: e.createTime, dir: dir, into: index)
            } else {
                index.file(parent: token, name: e.name, allocSize: e.allocSize,
                           modTime: e.modTime, createTime: e.createTime)
            }
        }
    }

    /// Shared work queue + result collector. The queue is a stack guarded by an NSCondition,
    /// with an `outstanding` counter (popped-but-not-completed) for termination.
    private final class Shared {
        private let cond = NSCondition()
        private var pending: [String]
        private var outstanding = 0

        // Dedup set on its own cheap lock: it's touched once per directory (hot), while the
        // condvar is now only touched once per CHUNK — keeping them separate stops the
        // per-directory check from convoying the work queue.
        private let visitedLock = NSLock()
        private var visited = Set<DevIno>()

        private(set) var byPath: [String: [DiskScopeScanner.Entry]] = [:]
        private(set) var errors = 0

        private let onProgress: ((Int, UInt64) -> Void)?
        private var count = 0
        private var bytes: UInt64 = 0
        private var lastReported = 0

        init(seed: String, onProgress: ((Int, UInt64) -> Void)?) {
            pending = [seed]
            self.onProgress = onProgress
            byPath.reserveCapacity(1 << 16)
        }

        func pop() -> String? {
            cond.lock(); defer { cond.unlock() }
            while pending.isEmpty && outstanding > 0 { cond.wait() }
            guard let p = pending.popLast() else { return nil } // empty + nothing outstanding = done
            outstanding += 1
            return p
        }

        /// Mid-chunk spill: enqueue work WITHOUT completing the chunk (outstanding is
        /// untouched, so termination stays correct — the pusher is still active).
        func push(children: [String]) {
            guard !children.isEmpty else { return }
            cond.lock()
            pending.append(contentsOf: children)
            for _ in 0..<children.count { cond.signal() }
            cond.unlock()
        }

        func complete(children: [String], entries: Int, bytes b: UInt64) {
            cond.lock()
            pending.append(contentsOf: children)
            outstanding -= 1
            count += entries; bytes += b
            if count - lastReported >= 8192 {
                lastReported = count
                onProgress?(count, bytes)
            }
            if outstanding == 0 && pending.isEmpty {
                cond.broadcast()                 // final release: wake everyone to terminate
            } else {
                for _ in 0..<children.count { cond.signal() } // wake only as many as enqueued
            }
            cond.unlock()
        }

        /// True the first time this (device, inode) is seen — false for duplicates.
        func firstVisit(dev: UInt64, ino: UInt64) -> Bool {
            visitedLock.lock(); defer { visitedLock.unlock() }
            return visited.insert(DevIno(dev: dev, ino: ino)).inserted
        }

        func merge(_ results: [(path: String, entries: [DiskScopeScanner.Entry])], errors e: Int) {
            cond.lock()
            for (p, entries) in results { byPath[p] = entries }
            errors += e
            cond.unlock()
        }
    }
}
