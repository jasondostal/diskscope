import SwiftUI
import AppKit
import DiskScopeCore

let bg = Color(red: 0.043, green: 0.051, blue: 0.063) // #0b0d10

struct ContentView: View {
    @StateObject private var model = TreemapModel()
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var settings: SettingsStore
    @State private var selected: Int?
    @State private var hover: HoverInfo?
    @State private var hasFDA = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if !hasFDA { fdaBanner }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(theme.current.palette.backgroundColor)
        .frame(minWidth: 860, minHeight: 600)
        .onAppear {
            model.setPalette(theme.current.palette)
            model.setMinSide(settings.minTileSize)
            hasFDA = FullDiskAccess.granted()
        }
        .onChange(of: theme.paletteRevision) { _, _ in model.setPalette(theme.current.palette) }
        .onChange(of: settings.minTileSize) { _, v in model.setMinSide(v) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { hasFDA = FullDiskAccess.granted() } // re-check after returning from Settings
        }
    }

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.yellow)
            Text("Full Disk Access is off — protected folders won't be counted.")
                .font(.callout)
            Spacer()
            Button("Grant Access…") { FullDiskAccess.openSystemSettings() }
            Button("Re-check") { hasFDA = FullDiskAccess.granted() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.yellow.opacity(0.10))
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
    }

    private var themeMenu: some View {
        Menu {
            ForEach(Theme.presets) { t in
                Button { theme.selectedID = t.id } label: {
                    if theme.selectedID == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
            Divider()
            Button { theme.selectedID = Theme.customID } label: {
                if theme.isCustom { Label("Custom", systemImage: "checkmark") } else { Text("Custom") }
            }
            Button("Customize This…") {
                theme.customize(from: theme.selectedID)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } label: { Image(systemName: "paintpalette") }
        .menuStyle(.borderlessButton).frame(width: 34)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            emptyState
        case .scanning:
            VStack(spacing: 14) {
                if let f = model.scanFraction {
                    ProgressView(value: f).frame(width: 280)
                    Text("\(Int(f * 100))%").font(.title2).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text("\(model.scannedCount.formatted()) items · \(humanSize(model.scannedBytes))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Text(model.path).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360)
            }
        case .ready:
            VSplitView {
                HSplitView {
                    TreeListView(model: model, selected: $selected)
                        .frame(minWidth: 360, minHeight: 140)
                    LegendView(model: model)
                        .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
                }
                .frame(minHeight: 150)
                TreemapCanvas(model: model, selected: $selected, hover: $hover)
                    .frame(minHeight: 200)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 52)).foregroundStyle(.tertiary)
            Text("Pick a folder to map").font(.title2).foregroundStyle(.secondary)
            HStack {
                Button("Choose Folder…") { chooseFolder() }.buttonStyle(.borderedProminent)
                Button("Scan Home") { scan(NSHomeDirectory()) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("DiskScope").font(.headline)
            if model.state == .ready {
                Text(model.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.state == .ready {
                Text("\(humanSize(model.totalSize)) · \(model.fileCount.formatted()) files · \(String(format: "%.1fs", model.scanSeconds))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button { model.scan(model.path) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                themeMenu
                Button("Choose…") { chooseFolder() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            if let h = hover {
                Text(h.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(humanSize(h.size)).monospacedDigit()
            } else {
                Text(model.state == .ready ? "Hover a cell to inspect · click to select · pick a folder in the tree to highlight it" : " ")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout).padding(.horizontal, 14).padding(.vertical, 7).frame(height: 30)
    }

    private func scan(_ path: String) { selected = nil; hover = nil; model.scan(path) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { scan(url.path) }
    }
}

// MARK: - Tree list

struct TreeListView: View {
    @ObservedObject var model: TreemapModel
    @Binding var selected: Int?
    @State private var expanded: Set<Int> = [0]

    var body: some View {
        if let root = model.makeRootNode() {
            VStack(spacing: 0) {
                treeHeader
                Divider().overlay(Color.white.opacity(0.08))
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        NodeRows(node: root, model: model, expanded: $expanded, depth: 0)
                    }
                    .listStyle(.inset)
                    .environment(\.defaultMinListRowHeight, 22)
                    .onChange(of: model.path) { _, _ in expanded = [0] }
                    .onChange(of: selected) { _, sel in
                        guard let sel else { return }
                        // Reveal: expand the selection's ancestor folders, then scroll to it.
                        for ancestor in model.ancestors(of: sel).dropLast() { expanded.insert(ancestor) }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(sel, anchor: .center) }
                        }
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    // Labels the fixed right-side columns; widths mirror TreeRow so they line up.
    private var treeHeader: some View {
        HStack(spacing: 6) {
            Text("Name")
            Spacer(minLength: 6)
            Color.clear.frame(width: 46)                       // %-bar
            Text("%").frame(width: 42, alignment: .trailing)
            Text("Files").frame(width: 52, alignment: .trailing)
            Text("Size").frame(width: 70, alignment: .trailing)
            Text("Modified").frame(width: 88, alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

/// Recursive outline row with explicit expansion control (so the treemap can reveal a path).
struct NodeRows: View {
    let node: TreeNode
    @ObservedObject var model: TreemapModel
    @Binding var expanded: Set<Int>
    let depth: Int

    var body: some View {
        TreeRow(node: node, total: model.totalSize, depth: depth,
                isExpanded: expanded.contains(node.id), palette: model.palette) {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        }
        .tag(node.id)
        .id(node.id)
        .contextMenu { fileMenu(model, node.id) }

        if node.isDir, expanded.contains(node.id), let kids = node.children {
            ForEach(kids) { child in
                NodeRows(node: child, model: model, expanded: $expanded, depth: depth + 1)
            }
        }
    }
}

struct TreeRow: View {
    let node: TreeNode
    let total: UInt64
    let depth: Int
    let isExpanded: Bool
    let palette: ThemePalette
    let onToggle: () -> Void

    private var fraction: Double { total > 0 ? Double(node.size) / Double(total) : 0 }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 12)
            if node.isDir {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12)
            }
            Image(systemName: node.isDir ? "folder.fill" : iconForExt(extOf(node.name)))
                .font(.caption2)
                .foregroundStyle(node.isDir ? Color.secondary : palette.color(FilePalette.category(forExt: extOf(node.name))))
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            PercentBar(fraction: fraction).frame(width: 46, height: 7)
            Text(String(format: "%.1f%%", fraction * 100))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            Text(node.isDir ? node.subtreeFiles.formatted() : "")
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(humanSize(node.size))
                .font(.caption).monospacedDigit().foregroundStyle(.primary)
                .frame(width: 70, alignment: .trailing)
            Text(shortDate(node.modTime))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .trailing)
        }
    }
}

func iconForExt(_ e: String) -> String {
    switch FilePalette.category(forExt: e) {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "music.note"
    case .archive: return "archivebox"
    case .code, .web: return "chevron.left.forwardslash.chevron.right"
    case .document: return "doc.text"
    case .data: return "tablecells"
    case .binary, .system: return "gearshape"
    case .other: return "doc"
    }
}

struct PercentBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color(red: 0.34, green: 0.62, blue: 0.92))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

// MARK: - Legend

struct LegendView: View {
    @ObservedObject var model: TreemapModel
    var body: some View {
        List {
            Section("File types — \(model.legend.count)") {
                ForEach(model.legend) { e in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(model.palette.color(FilePalette.category(forExt: e.ext.hasPrefix("·") ? "" : e.ext)))
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.displayExt).font(.callout).monospacedDigit()
                            Text(e.ext.hasPrefix("·") ? "\(e.count.formatted()) files" : FilePalette.description(forExt: e.ext))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(humanSize(e.bytes)).font(.caption).monospacedDigit()
                            Text(String(format: "%.1f%%", e.fraction * 100))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Treemap

struct HoverInfo: Equatable { let node: Int; let path: String; let size: UInt64 }

struct TreemapCanvas: View {
    @ObservedObject var model: TreemapModel
    @Binding var selected: Int?
    @Binding var hover: HoverInfo?

    var body: some View {
        GeometryReader { geo in
            let tiles = model.tiles(for: geo.size)
            ZStack {
                // Cushioned, Phong-shaded leaves (bitmap).
                if let img = model.cushionImage(for: geo.size) {
                    Image(decorative: img, scale: 1).resizable().frame(width: geo.size.width, height: geo.size.height)
                }
                // Overlays: structure + selection + hover outlines.
                Canvas { ctx, _ in
                    for t in tiles where t.isDir && t.depth == 1 {
                        ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(0.20)), lineWidth: 1)
                    }
                    if let sel = selected, let t = tiles.first(where: { $0.node == sel }) {
                        ctx.stroke(Path(cg(t.rect)), with: .color(.white), lineWidth: 2)
                    }
                    if let h = hover, h.node != selected, let t = tiles.first(where: { $0.node == h.node }) {
                        ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(0.6)), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    if let t = hitTest(tiles, pt), let info = model.info(for: t.node) {
                        hover = HoverInfo(node: t.node, path: info.path, size: info.size)
                    } else { hover = nil }
                case .ended: hover = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { ev in
                if let t = hitTest(tiles, ev.location) { selected = t.node }
            })
            .contextMenu {
                if let node = hover?.node ?? selected { fileMenu(model, node) }
            }
        }
    }

    private func cg(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: max(0, r.w), height: max(0, r.h)) }

    private func hitTest(_ tiles: [TreemapTile], _ p: CGPoint) -> TreemapTile? {
        tiles.last { !$0.isDir && cg($0.rect).contains(p) }
    }
}

// MARK: - Color helpers

@ViewBuilder
func fileMenu(_ model: TreemapModel, _ node: Int) -> some View {
    Button { model.reveal(node) } label: { Label("Reveal in Finder", systemImage: "folder") }
    Button { model.open(node) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
    Divider()
    Button(role: .destructive) { model.moveToTrash(node) } label: { Label("Move to Trash", systemImage: "trash") }
}

func categoryColor(_ cat: FilePalette.Category) -> Color { oklchColor(FilePalette.oklch(cat)) }

func oklchColor(_ c: FilePalette.OKLCH) -> Color {
    let rgb = FilePalette.srgb(c)
    return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
}
