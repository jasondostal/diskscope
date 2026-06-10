import Foundation
import AppKit
import SwiftUI
import DiskScopeCore

/// One reclaimable-space row: a known macOS/dev-tool space hog found in the CURRENT index
/// (no extra disk walk — sizes come from the already-scanned arena).
struct ReclaimableItem: Identifiable {
    /// A single node the UI can select/reveal, or a by-name aggregate (e.g. node_modules).
    enum Kind {
        case node(Int)
        case aggregate(name: String)
    }
    let id: String
    let title: String
    let detail: String     // what it is and why it's (relatively) safe to reclaim
    let bytes: UInt64
    let count: Int         // 1 for single paths; N topmost folders for aggregates
    let kind: Kind
}

/// The "where did my disk go" reconciliation for the pane header: what the treemap can
/// see vs what the volume reports, plus the snapshot situation that explains the gap.
struct SpaceAccounting {
    let scannedBytes: UInt64
    let volumeUsedBytes: UInt64
    let snapshotCount: Int
    let oldestSnapshot: String?   // "2026-06-08 23:23"
    let unreadableDirs: Int
    var gap: UInt64 { volumeUsedBytes > scannedBytes ? volumeUsedBytes - scannedBytes : 0 }
}

enum Reclaimables {

    /// Known space hogs, home-relative. Only rows that exist INSIDE the current scan (and
    /// clear a size floor) are shown — scanning a subfolder naturally hides the rest.
    private static let knownHogs: [(rel: String, title: String, detail: String)] = [
        (".Trash", "Trash", "Deleted files waiting for Empty Trash"),
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Build caches — Xcode regenerates them on demand"),
        ("Library/Developer/Xcode/Archives", "Xcode Archives", "App archives — keep only ones you still distribute"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", "Debug symbols for devices you've attached — old ones are dead weight"),
        ("Library/Developer/CoreSimulator", "iOS Simulators", "Simulator runtimes and device data"),
        ("Library/Caches", "User caches", "App caches — rebuilt as needed (expect them to regrow)"),
        ("Library/Logs", "Logs", "Diagnostic logs"),
        ("Library/Application Support/MobileSync/Backup", "iOS device backups", "Local iPhone/iPad backups — verify before deleting"),
        ("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker disk image", "Docker Desktop's VM disk — prune images/volumes inside Docker to shrink it"),
        (".orbstack", "OrbStack data", "OrbStack VMs and container data"),
        (".npm", "npm cache", "Package cache — npm re-downloads as needed"),
        (".cargo/registry", "Cargo registry", "Rust crate cache — re-downloaded as needed"),
        ("go/pkg/mod", "Go module cache", "Module cache — re-downloaded as needed"),
    ]

    /// Aggregates summed by directory NAME across the whole scan (topmost-only, so nested
    /// instances aren't double-billed).
    private static let aggregates: [(name: String, title: String, detail: String)] = [
        ("node_modules", "node_modules folders", "Topmost node_modules across the scan — npm/yarn reinstall them"),
        ("DerivedData", "Stray DerivedData", "DerivedData folders outside the default location"),
    ]

    private static let sizeFloor: UInt64 = 50 * 1024 * 1024 // 50 MB — density without noise

    /// Build the row list from the live index. Cheap: a handful of path lookups plus one
    /// linear name pass per aggregate.
    static func compute(index: FileIndex) -> [ReclaimableItem] {
        var items: [ReclaimableItem] = []
        let home = NSHomeDirectory()

        for hog in knownHogs {
            let path = home + "/" + hog.rel
            guard let node = index.node(forPath: path) else { continue }
            let n = index.nodes[node]
            let bytes = n.isDir ? n.totalSize : n.ownSize
            guard bytes >= sizeFloor else { continue }
            items.append(ReclaimableItem(id: hog.rel, title: hog.title, detail: hog.detail,
                                         bytes: bytes, count: 1, kind: .node(node)))
        }
        for agg in aggregates {
            let (bytes, count) = index.aggregateDirs(named: agg.name)
            // The default DerivedData location already has its own row — don't bill it twice.
            var net = bytes
            if agg.name == "DerivedData",
               let dd = index.node(forPath: home + "/Library/Developer/Xcode/DerivedData") {
                net = bytes >= index.nodes[dd].totalSize ? bytes - index.nodes[dd].totalSize : 0
            }
            guard net >= sizeFloor, count > 0 else { continue }
            items.append(ReclaimableItem(id: "agg:" + agg.name, title: agg.title, detail: agg.detail,
                                         bytes: net, count: count, kind: .aggregate(name: agg.name)))
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Local Time Machine snapshots

    /// Count + oldest timestamp of APFS local snapshots on the root volume (tmutil; ~ms).
    /// Blocking Process — call off-main.
    static func localSnapshots() -> (count: Int, oldest: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (0, nil) }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let stamps = out.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
            let s = line[r]                       // 2026-06-08-232350
            let hhmm = s.dropFirst(11)
            return "\(s.prefix(10)) \(hhmm.prefix(2)):\(hhmm.dropFirst(2).prefix(2))"
        }.sorted()
        return (stamps.count, stamps.first)
    }

    /// Aggressively thin local snapshots (asks for an admin password via the OS prompt —
    /// snapshot deletion is root-only). Returns tmutil's output, or the error. Blocking —
    /// call off-main. Snapshots regenerate hourly while Time Machine is on; this reclaims
    /// the space they're currently holding, it doesn't disable anything.
    static func thinLocalSnapshots() -> String {
        let src = "do shell script \"tmutil thinlocalsnapshots / 999999999999 4\" with administrator privileges"
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let msg = err?[NSAppleScript.errorMessage] as? String { return "Failed: \(msg)" }
        return result?.stringValue ?? "Done"
    }
}

// MARK: - Reclaim pane (right column, behind the File types / Reclaim toggle)

/// "Where did my disk go" reconciliation + known space hogs. Items select/reveal — they
/// never delete directly; look first, then trash via the context menu you already trust.
struct ReclaimView: View {
    @ObservedObject var model: TreemapModel
    @Binding var selected: Int?
    @State private var accounting: SpaceAccounting?
    @State private var items: [ReclaimableItem] = []
    @State private var thinning = false
    @State private var thinResult: String?

    var body: some View {
        List {
            Section {
                accountingRows
            } header: {
                Text("Where the disk went")
            }
            Section {
                if items.isEmpty {
                    Text("Nothing over 50 MB in the usual suspects.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(items) { itemRow($0) }
                }
            } header: {
                Text("Reclaimable — \(items.count)")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refresh)
        .onChange(of: model.revision) { _, _ in refresh() }
    }

    private func refresh() {
        items = model.reclaimables()
        model.spaceAccounting { accounting = $0 }
    }

    // The files-vs-volume gap is only meaningful for a whole-disk scan; snapshots are
    // volume-wide and always worth showing.
    @ViewBuilder private var accountingRows: some View {
        if let a = accounting {
            if model.path == "/" {
                statRow("Files (scanned)", humanSize(a.scannedBytes))
                statRow("Volume used", humanSize(a.volumeUsedBytes))
                statRow("Snapshots + purgeable", "≈ " + humanSize(a.gap))
                    .foregroundStyle(.orange)
            } else {
                Text("Scan Macintosh HD (/) for full-disk accounting.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if a.snapshotCount > 0 {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(a.snapshotCount) local Time Machine snapshots")
                            .font(.caption)
                        if let o = a.oldestSnapshot {
                            Text("oldest \(o) · they hold deleted/changed blocks")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button(thinning ? "Thinning…" : "Thin…") { thin() }
                        .controlSize(.small).disabled(thinning)
                        .help("tmutil thinlocalsnapshots — asks for an admin password; snapshots regrow hourly while Time Machine is on")
                }
            }
            if let r = thinResult {
                Text(r).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
            }
            if a.unreadableDirs > 0 {
                Text("\(a.unreadableDirs.formatted()) folders unreadable — grant Full Disk Access for a complete count.")
                    .font(.caption2).foregroundStyle(.yellow)
            }
        } else {
            Text("…").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }

    private func itemRow(_ item: ReclaimableItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: item)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.title).font(.callout).lineLimit(1)
                    if item.count > 1 {
                        Text("× \(item.count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(item.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Text(humanSize(item.bytes)).font(.caption).monospacedDigit()
            if case .node(let node) = item.kind {
                Button { selected = node } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless).help("Select in tree & treemap")
                Button { model.reveal(node) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
        }
        .padding(.vertical, 1)
    }

    private func icon(for item: ReclaimableItem) -> String {
        switch item.id {
        case ".Trash": return "trash"
        case let s where s.contains("Docker") || s.contains("orbstack"): return "shippingbox"
        case let s where s.contains("Backup"): return "iphone"
        case "agg:node_modules": return "cube.box"
        default: return "internaldrive"
        }
    }

    private func thin() {
        thinning = true
        thinResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Reclaimables.thinLocalSnapshots()
            DispatchQueue.main.async {
                thinning = false
                thinResult = r
                model.spaceAccounting { accounting = $0 } // re-measure the gap
            }
        }
    }
}
