import Foundation
import Darwin

/// Always-on, multi-volume search: one FileIndex per local volume — warm-started when a
/// snapshot exists, cold-scanned in the background otherwise — kept current by FSEvents,
/// queried as a single namespace. This is the engine behind the menu-bar agent's ⌥Space
/// panel; the app window's TreemapModel stays its own single-root world.
///
/// Concurrency: ONE serial queue owns every index. Reconciles and searches both hop
/// through it (searches are ~ms, so a sync hop from the UI is cheap); the expensive
/// initial builds run OFF the queue and only the install hops on.
public final class SearchService {

    public enum VolumeStatus: Equatable {
        case scanning
        case ready(entries: Int)
        case failed
    }
    public struct VolumeInfo: Identifiable, Equatable {
        public let root: String
        public let status: VolumeStatus
        public var id: String { root }
    }

    private final class Volume {
        let root: String
        var index: FileIndex?
        var watcher: FSEventsWatcher?
        var preScanEventID: UInt64 = 0
        var status: VolumeStatus = .scanning
        init(root: String) { self.root = root }
    }

    private let queue = DispatchQueue(label: "com.diskscope.searchservice", qos: .userInitiated)
    private var volumes: [String: Volume] = [:]
    /// Fired on the MAIN queue whenever any volume's status changes (drives the menu UI).
    public var onChange: (([VolumeInfo]) -> Void)?

    public init() {}

    // MARK: - Volume enumeration

    /// "/" plus every local, user-visible volume mounted under /Volumes. Network mounts,
    /// hidden system mounts, and the volume-group members under /System/Volumes (already
    /// reachable through "/" via firmlinks) are excluded.
    public static func localVolumeRoots() -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mounts, MNT_NOWAIT)
        var roots: Set<String> = ["/"]
        if n > 0, let mounts {
            for i in 0..<Int(n) {
                let m = mounts[i]
                guard m.f_flags & UInt32(MNT_LOCAL) != 0,
                      m.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
                let mnt = withUnsafeBytes(of: m.f_mntonname) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                if mnt.hasPrefix("/Volumes/") { roots.insert(mnt) }
            }
        }
        return roots.sorted()
    }

    // MARK: - Lifecycle

    public func start(roots: [String] = SearchService.localVolumeRoots()) {
        for r in roots { addVolume(root: r) }
    }

    /// Index a volume (no-op if already tracked). Warm start or cold scan happens off the
    /// service queue so searches against OTHER volumes stay responsive throughout.
    public func addVolume(root: String) {
        queue.async { [self] in
            guard volumes[root] == nil else { return }
            let vol = Volume(root: root)
            volumes[root] = vol
            notify()
            DispatchQueue.global(qos: .utility).async { [self] in
                let pre = FSEventsWatcher.currentEventId()
                let index: FileIndex
                if let warm = WarmStart.load(root: root) {
                    index = warm.index
                } else {
                    let built = ParallelIndexBuilder.build(root: root)
                    built.aggregate()
                    WarmStart.save(built, root: root, eventID: pre)
                    index = built
                }
                let entries = index.count
                queue.async { [self] in
                    guard let v = volumes[root] else { return } // unmounted mid-scan
                    v.index = index
                    v.preScanEventID = pre
                    v.status = .ready(entries: entries)
                    startWatching(v)
                    notify()
                }
            }
        }
    }

    /// Drop a volume (unmount). Its snapshot stays on disk — remounting warm-starts.
    public func removeVolume(root: String) {
        queue.async { [self] in
            guard let v = volumes.removeValue(forKey: root) else { return }
            v.watcher?.stop()
            notify()
        }
    }

    /// Persist every ready index (app quit). With live watchers the indexes are current,
    /// so "now" is the honest journal cursor.
    public func saveAll() {
        queue.sync { [self] in
            for v in volumes.values {
                guard let idx = v.index else { continue }
                let id = v.watcher != nil ? FSEventsWatcher.currentEventId() : v.preScanEventID
                WarmStart.save(idx, root: v.root, eventID: id)
            }
        }
    }

    // MARK: - Search

    /// Query every ready volume and merge by (rank, size desc) — one namespace.
    public func search(_ raw: String, limit: Int = 60) -> [SearchResult] {
        queue.sync { [self] in
            var all: [SearchResult] = []
            for v in volumes.values {
                guard let idx = v.index else { continue }
                all.append(contentsOf: idx.search(raw, limit: limit))
            }
            all.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.size > $1.size }
            return Array(all.prefix(limit))
        }
    }

    // MARK: - Live updates

    private func startWatching(_ vol: Volume) {
        let root = vol.root
        let w = FSEventsWatcher(roots: [root]) { [weak self] dirs, deep in
            guard let self else { return }
            self.queue.async {
                guard let v = self.volumes[root], let idx = v.index else { return }
                for d in dirs {
                    if deep.contains(d) { idx.reconcileSubtree(directoryPath: d) }
                    else { idx.reconcile(directoryPath: d) }
                }
            }
        }
        w.onInvalidated = { [weak self] in
            // Journal unreliable — rebuild this volume from scratch.
            guard let self else { return }
            self.queue.async {
                guard let v = self.volumes.removeValue(forKey: root) else { return }
                v.watcher?.stop()
                self.notify()
            }
            self.addVolume(root: root)
        }
        if w.start() { vol.watcher = w }
    }

    private func notify() {
        let infos = volumes.values
            .map { VolumeInfo(root: $0.root, status: $0.status) }
            .sorted { $0.root < $1.root }
        DispatchQueue.main.async { [onChange] in onChange?(infos) }
    }
}
