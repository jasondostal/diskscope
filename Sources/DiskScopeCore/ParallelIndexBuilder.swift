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

    /// Scan `root` in parallel and return the assembled, ready-to-aggregate index.
    /// `onProgress(count, bytes)` is called periodically from a worker (off the main thread).
    public static func build(root: String, workers: Int = performanceCoreCount(),
                             onProgress: ((Int, UInt64) -> Void)? = nil) -> FileIndex {
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

    private static func workerLoop(_ shared: Shared) {
        var local: [(path: String, entries: [DiskScopeScanner.Entry])] = []
        var localErrors = 0
        while let path = shared.pop() {
            guard let level = DiskScopeScanner.scanLevel(path: path) else {
                localErrors += 1
                shared.complete(children: [], entries: 0, bytes: 0)
                continue
            }
            // Dedup by (device, inode): firmlinks (e.g. /Users and /System/Volumes/Data/Users
            // on APFS) and bind mounts expose the same directory under two paths — count once.
            guard shared.firstVisit(dev: level.dev, ino: level.ino) else {
                shared.complete(children: [], entries: 0, bytes: 0)
                continue
            }
            let prefix = path == "/" ? "/" : path + "/"
            let childDirs = level.entries.lazy.filter { $0.isDir }.map { prefix + $0.name }
            let bytes = level.entries.reduce(UInt64(0)) { $0 + ($1.isDir ? 0 : $1.allocSize) }
            local.append((path, level.entries))
            shared.complete(children: Array(childDirs), entries: level.entries.count, bytes: bytes)
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
            cond.lock(); defer { cond.unlock() }
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
