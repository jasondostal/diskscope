import Foundation
import DiskScopeCore

// Phase 0 spike: scan a path, report how fast.
//   diskscope-scan <path> [workers]
// workers omitted or 1 -> serial scanner; >1 -> parallel worker pool.
//   diskscope-scan /System/Volumes/Data 18
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
