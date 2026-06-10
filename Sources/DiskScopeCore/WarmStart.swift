import Foundation

/// Cold scans should happen once per volume, ever. WarmStart loads the persisted index
/// (IndexStore) and replays only the FSEvents journal since it was saved — the same trick
/// Everything uses with the NTFS USN journal, with FSEvents as the macOS analog. Any doubt
/// (no snapshot, journal wrapped, rescan flag at the root, replay timeout) returns nil and
/// the caller falls back to a normal full scan.
public enum WarmStart {

    public struct Result {
        public let index: FileIndex
        /// Directories the replay reconciled (0 = nothing changed since last save).
        public let replayedDirs: Int
        public let seconds: Double
    }

    public static func load(root: String, timeout: TimeInterval = 10) -> Result? {
        let t0 = DispatchTime.now()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue,
              let (index, eventID) = IndexStore.load(root: root) else { return nil }
        index.aggregate()

        // Replay the journal since the snapshot. Events arrive batched on the watcher's
        // queue; HistoryDone marks the end of the backlog.
        let lock = NSLock()
        var dirs = Set<String>()
        var deep = Set<String>()
        var invalid = false
        let done = DispatchSemaphore(value: 0)

        let watcher = FSEventsWatcher(roots: [root], sinceEventId: eventID) { batch, deepBatch in
            lock.lock()
            dirs.formUnion(batch)
            deep.formUnion(deepBatch)
            lock.unlock()
        }
        watcher.onHistoryDone = { done.signal() }
        watcher.onInvalidated = { lock.lock(); invalid = true; lock.unlock(); done.signal() }
        guard watcher.start() else { return nil }
        let waited = done.wait(timeout: .now() + timeout)
        watcher.stop()

        lock.lock()
        let replayDirs = dirs
        let replayDeep = deep
        let isInvalid = invalid
        lock.unlock()
        guard waited == .success, !isInvalid else { return nil }

        // Deep (subtree) reconciles first; the root itself deep = caller rescans.
        for d in replayDeep {
            if d == root || root.hasPrefix(d == "/" ? "/" : d + "/") { return nil }
            index.reconcileSubtree(directoryPath: d)
        }
        for d in replayDirs.subtracting(replayDeep) {
            index.reconcile(directoryPath: d)
        }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        return Result(index: index, replayedDirs: replayDirs.count, seconds: secs)
    }

    /// Persist `index` as the warm-start snapshot for `root`. `eventID` should be the
    /// FSEvents ID up to which the index is known current: the ID captured at scan start
    /// (full scan), or "now" if a live watcher has been reconciling continuously.
    public static func save(_ index: FileIndex, root: String, eventID: UInt64) {
        try? IndexStore.save(index, root: root, eventID: eventID)
    }
}
