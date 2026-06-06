import Foundation
import DiskScopeCore

// diskscope-scan <path> [workers]      — scan a path, report count + wall-clock
// diskscope-scan --watch <path>        — build index, watch live, print reconcile deltas
//   workers omitted or 1 -> serial scanner; >1 -> parallel worker pool.

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--watch" {
    setvbuf(stdout, nil, _IONBF, 0) // unbuffered: deltas appear live, survive Ctrl-C
    // FSEvents reports canonical (symlink-resolved) paths, so the index must be keyed on
    // the canonical root too — else every reconcile lookup misses (/tmp -> /private/tmp).
    var rbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let root = realpath(CommandLine.arguments[2], &rbuf) != nil
        ? String(cString: rbuf) : CommandLine.arguments[2]
    let index = FileIndex()
    let t0 = DispatchTime.now()
    DiskScopeScanner.scan(path: root, into: index)
    index.aggregate()
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    print("indexed \(index.count) entries in \(String(format: "%.2f", secs))s — watching \(root)")
    print("(touch/create/delete files under it; Ctrl-C to stop)\n")

    let watcher = FSEventsWatcher(roots: [root]) { dirs, deep in
        for dir in dirs {
            let d = index.reconcile(directoryPath: dir)
            if d.changed {
                print("Δ \(dir)  +\(d.added) -\(d.removed) ~\(d.updated)   [now \(index.count) entries]")
            }
        }
        _ = deep // (recursive subtree reconcile: a later refinement)
    }
    guard watcher.start() else {
        FileHandle.standardError.write("failed to start FSEvents stream (Full Disk Access?)\n".data(using: .utf8)!)
        exit(1)
    }
    RunLoop.main.run()
}

// diskscope-scan --treemap <path> [out.svg]  — scan, lay out, render a treemap image
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--treemap" {
    let target = CommandLine.arguments[2]
    let out = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/tmp/diskscope-treemap.svg"
    let index = FileIndex()
    let t0 = DispatchTime.now()
    DiskScopeScanner.scan(path: target, into: index)
    index.aggregate()
    let canvas = Rect(x: 0, y: 0, w: 1600, h: 1000)
    let tiles = Treemap.layout(index, root: 0, in: canvas, minSide: 1.5)
    let svg = TreemapSVG.render(tiles: tiles, index: index, canvas: canvas)
    try? svg.write(toFile: out, atomically: true, encoding: .utf8)
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    let leaves = tiles.filter { !$0.isDir }.count
    print("treemap: \(index.count) entries → \(tiles.count) tiles (\(leaves) files drawn) in \(String(format: "%.2f", secs))s")
    print("wrote \(out)")

    // Proportionality check: tile area should track file size with a ~constant ratio.
    if ProcessInfo.processInfo.environment["DSDEBUG"] != nil {
        let leafTiles = tiles.filter { !$0.isDir }
            .map { (size: index.nodes[$0.node].ownSize, area: $0.rect.area, name: index.nodes[$0.node].name) }
            .sorted { $0.size > $1.size }
        print("\nproportionality (area / byte should be ~constant):")
        for t in leafTiles.prefix(6) {
            print(String(format: "  %12llu B  area=%9.1f  ratio=%.6f  %@", t.size, t.area, t.area / Double(max(1, t.size)), t.name))
        }
        if let mid = leafTiles.dropFirst(leafTiles.count / 2).first {
            print(String(format: "  %12llu B  area=%9.1f  ratio=%.6f  %@ (median-ish)", mid.size, mid.area, mid.area / Double(max(1, mid.size)), mid.name))
        }
    }
    exit(0)
}

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.homeDirectoryForCurrentUser.path
let workers = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 1) : 1

let mode = workers > 1 ? "parallel x\(workers)" : "serial"
FileHandle.standardError.write("scanning \(path) [\(mode)] ...\n".data(using: .utf8)!)

let start = DispatchTime.now()
let stats = workers > 1
    ? DiskScopeParallelScanner.scan(path: path, workers: workers)
    : DiskScopeScanner.scan(path: path)
let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

let total = stats.files + stats.dirs
let rate = seconds > 0 ? Double(total) / seconds : 0
let gib = Double(stats.allocBytes) / (1024 * 1024 * 1024)

func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

print("""
\u{2500}\u{2500} diskscope scan \u{2500}\u{2500}
entries   \(fmt(total))  (\(fmt(stats.files)) files, \(fmt(stats.dirs)) dirs)
size      \(String(format: "%.2f", gib)) GiB allocated
errors    \(fmt(stats.errors))  (unreadable dirs: SIP / no Full Disk Access)
time      \(String(format: "%.3f", seconds)) s
rate      \(fmt(Int(rate))) entries/sec
""")
