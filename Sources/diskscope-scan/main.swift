import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DiskScopeCore

func cliExt(_ n: String) -> String {
    guard let d = n.lastIndex(of: "."), d != n.startIndex else { return "" }
    return String(n[n.index(after: d)...]).lowercased()
}

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to path: String) {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

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

// diskscope-scan --cushion <path> [out.png]  — render the cushioned treemap to PNG (preview)
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--cushion" {
    let target = CommandLine.arguments[2]
    let out = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/tmp/diskscope-cushion.png"
    let index = FileIndex()
    DiskScopeScanner.scan(path: target, into: index)
    index.aggregate()
    let W = 1600, H = 1000
    let tiles = Treemap.layout(index, root: 0, in: Rect(x: 0, y: 0, w: Double(W), h: Double(H)),
                               minSide: 1.5, cushionHeight: 0.42)
    let rgba = Treemap.renderCushionRGBA(tiles: tiles, width: W, height: H, ambient: 0.58) { node in
        FilePalette.srgb(forExt: cliExt(index.nodes[node].name))
    }
    writePNG(rgba, width: W, height: H, to: out)
    print("cushion: \(tiles.count) tiles → \(out)")
    exit(0)
}

// diskscope-scan --term <path>  — render the cushioned treemap in the terminal itself,
// via Unicode half-blocks (▀) + 24-bit truecolor: two vertical pixels per character cell.
// Same engine, same cushion renderer as the GUI — just a different output target.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--term" {
    let target = CommandLine.arguments[2]
    var ws = winsize()
    let cols: Int, rows: Int
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        cols = Int(ws.ws_col); rows = Int(ws.ws_row)
    } else {
        cols = 100; rows = 44
    }
    let W = cols, H = max(2, (rows - 1) * 2) // one row reserved for the caption

    let index = FileIndex()
    DiskScopeScanner.scan(path: target, into: index)
    index.aggregate()
    let tiles = Treemap.layout(index, root: 0, in: Rect(x: 0, y: 0, w: Double(W), h: Double(H)),
                               minSide: 1, cushionHeight: 0.42)
    let rgba = Treemap.renderCushionRGBA(tiles: tiles, width: W, height: H, ambient: 0.58) { node in
        FilePalette.srgb(forExt: cliExt(index.nodes[node].name))
    }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * W + x) * 4
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
    }

    var out = ""
    var y = 0
    while y + 1 < H {
        for x in 0..<W {
            let (tr, tg, tb) = px(x, y)
            let (br, bg, bb) = px(x, y + 1)
            out += "\u{1b}[38;2;\(tr);\(tg);\(tb)m\u{1b}[48;2;\(br);\(bg);\(bb)m▀"
        }
        out += "\u{1b}[0m\n"
        y += 2
    }
    let total = Int64(index.nodes.first?.totalSize ?? 0)
    let sizeStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    out += "\u{1b}[0m \(target)  —  \(index.fileCount) files · \(sizeStr)\n"
    print(out, terminator: "")
    exit(0)
}

// diskscope-scan --index <path> [workers]  — benchmark serial vs parallel INDEX build
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--index" {
    let target = CommandLine.arguments[2]
    let w = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? ParallelIndexBuilder.performanceCoreCount()) : ParallelIndexBuilder.performanceCoreCount()

    func time(_ label: String, _ body: () -> FileIndex) {
        let t0 = DispatchTime.now()
        let idx = body()
        idx.aggregate()
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        print("\(label): \(idx.fileCount.formatted()) files, \(idx.dirCount.formatted()) dirs in \(String(format: "%.2f", secs))s")
    }
    print("P-cores: \(ParallelIndexBuilder.performanceCoreCount())  ·  parallel workers: \(w)")
    time("serial  ") { let i = FileIndex(); DiskScopeScanner.scan(path: target, into: i); return i }
    time("parallel") { ParallelIndexBuilder.build(root: target, workers: w) }
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
