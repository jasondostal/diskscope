import Foundation
import CoreServices

/// Live filesystem delta source. Subscribes to FSEvents for the watched roots and reports
/// the set of directories that changed, coalesced per batch. The caller feeds each one to
/// `FileIndex.reconcile` — the watcher knows nothing about the index.
///
/// FSEvents is path-level and coalesced: we get "something under here changed," not a
/// per-file diff. So for every reported path we reconcile its containing directory (which
/// re-scans that level and patches), and for directory paths we reconcile the dir itself.
/// A coalesced "must scan subdirs" flag asks us to reconcile the whole subtree.
///
/// Threading: the handler runs on this watcher's private serial queue. The index it
/// mutates must only be touched from there (or marshal accordingly) — it is not yet
/// internally synchronized.
public final class FSEventsWatcher {

    /// Called with a batch of absolute directory paths to reconcile, plus whether any
    /// of them needs a recursive (subtree) reconcile.
    public typealias Handler = (_ dirs: [String], _ needsDeepScan: Set<String>) -> Void

    private let roots: [String]
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.diskscope.fsevents")
    private var stream: FSEventStreamRef?
    private let sinceEventId: UInt64?

    /// Fired once after a historical replay (`sinceEventId`) has fully drained — the
    /// kFSEventStreamEventFlagHistoryDone marker. Runs on the watcher's queue.
    public var onHistoryDone: (() -> Void)?
    /// Fired when the journal can't serve us reliably: event IDs wrapped, or the kernel
    /// asks for a recursive rescan at (or above) a watched root. Caller should full-rescan.
    public var onInvalidated: (() -> Void)?

    /// The volume-global FSEvents ID for "now" — capture this BEFORE a scan starts and
    /// save it with the index; replaying from it on next launch can only over-deliver
    /// (reconcile is idempotent), never miss.
    public static func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    public init(roots: [String], sinceEventId: UInt64? = nil, handler: @escaping Handler) {
        self.roots = roots
        self.sinceEventId = sinceEventId
        self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // FileEvents = per-file granularity; NoDefer = fire on the leading edge;
        // UseCFTypes = paths arrive as a CFArray of CFString.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)

        // Non-capturing C callback: recover `self` from the context info pointer.
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(rawPaths)
                .takeUnretainedValue() as? [String] else { return }

            var dirs = Set<String>()
            var deep = Set<String>()
            var historyDone = false
            var invalidated = false
            for i in 0..<count {
                let path = paths[i]
                let flag = Int(rawFlags[i])

                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    historyDone = true       // marker pseudo-event, no path to reconcile
                    continue
                }
                if flag & kFSEventStreamEventFlagEventIdsWrapped != 0 {
                    invalidated = true        // journal IDs wrapped — replay is unreliable
                    continue
                }
                let isDir = flag & kFSEventStreamEventFlagItemIsDir != 0

                if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                    // Coalesced: re-scan this whole subtree. At/above a root, the whole
                    // index is suspect — tell the caller to start over.
                    if watcher.roots.contains(where: { $0 == path || $0.hasPrefix(path == "/" ? "/" : path + "/") }) {
                        invalidated = true
                    } else {
                        dirs.insert(path); deep.insert(path)
                    }
                    continue
                }
                // Reconcile the containing directory (catches create/delete/rename of
                // this entry). If it's a directory event, also reconcile it directly.
                dirs.insert((path as NSString).deletingLastPathComponent)
                if isDir { dirs.insert(path) }
            }
            if !dirs.isEmpty { watcher.handler(Array(dirs), deep) }
            if invalidated { watcher.onInvalidated?() }
            if historyDone { watcher.onHistoryDone?() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            roots as CFArray,
            sinceEventId ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.10,                       // latency: coalesce bursts into ~100ms batches
            flags)
        else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
