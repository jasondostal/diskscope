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
    @Environment(\.openSettings) private var openSettings

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
            model.setRecency(theme.recency)
            model.setDepth(theme.depth)
            model.setMinSide(settings.minTileSize)
            hasFDA = FullDiskAccess.granted()
        }
        .onChange(of: theme.paletteRevision) { _, _ in
            model.setPalette(theme.current.palette)
            model.setRecency(theme.recency)
            model.setDepth(theme.depth)
        }
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
            Button { theme.selectedID = Theme.customID; openSettings() } label: {
                if theme.isCustom { Label("Custom", systemImage: "checkmark") } else { Text("Custom") }
            }
            Button("Customize This…") {
                theme.customize(from: theme.selectedID)
                openSettings()
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
                        .frame(minWidth: 320, minHeight: 140)
                    VStack(spacing: 0) {
                        DetailsView(model: model, selected: $selected)
                        Divider().overlay(Color.white.opacity(0.08))
                        LegendView(model: model)
                    }
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
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

    /// Basename of the scanned root — the prominent identity in the header.
    private var folderName: String {
        let n = (model.path as NSString).lastPathComponent
        return n.isEmpty ? model.path : n
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Identity zone (left): app title · prominent folder name · subtle full path.
            Text("DiskScope").font(.headline)
            if model.state == .ready {
                Text(folderName).font(.callout).fontWeight(.semibold).lineLimit(1).fixedSize()
                // The path is the only elastic element — it truncates first so nothing else jumps.
                Text(model.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
            Spacer(minLength: 12)
            // Stats + controls zone (right). fixedSize on the stats keeps the numbers from ever
            // truncating or wrapping; the Spacer absorbs length changes so the buttons stay put.
            if model.state == .ready {
                Text("\(humanSize(model.totalSize)) · \(model.fileCount.formatted()) files · \(String(format: "%.1fs", model.scanSeconds))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                // File actions as clean borderless icons (matching the theme menu), tooltips for clarity.
                HStack(spacing: 12) {
                    Button { model.scan(model.path) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan this folder")
                    Button { chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                        .help("Scan a different folder…")
                }
                .buttonStyle(.borderless).imageScale(.large)
                Divider().frame(height: 16)
                themeMenu
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
                Text(model.state == .ready ? "Hover to inspect · click to select · click a file type in the legend to isolate it" : " ")
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
            // Structured exactly like LegendView (a bare List with a Section header) — that's the
            // one shape that DOESN'T get macOS's phantom top inset. Wrapping the List in a VStack
            // or a safeAreaInset both reintroduced the big blank band above the rows.
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    Section {
                        NodeRows(node: root, model: model, expanded: $expanded, depth: 0)
                    } header: {
                        treeHeader
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
    case .model: return "brain"
    case .model3d: return "cube"
    case .binary, .system: return "gearshape"
    case .other: return "doc"
    }
}

struct PercentBar: View {
    let fraction: Double
    var color: Color = Color(red: 0.34, green: 0.62, blue: 0.92)
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

// MARK: - Details (inspector)

/// Right-pane top: stats for the selected file/folder (falls back to the scanned root).
struct DetailsView: View {
    @ObservedObject var model: TreemapModel
    @Binding var selected: Int?

    var body: some View {
        let s = model.stats(for: selected)
        VStack(alignment: .leading, spacing: 7) {
            if let s {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(s.isDir ? Color.secondary.opacity(0.5) : model.palette.color(s.category))
                        .frame(width: 13, height: 13)
                    Image(systemName: s.isDir ? "folder.fill" : iconForExt(s.ext))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(s.name).font(.headline).lineLimit(2).truncationMode(.middle)
                }
                Text(typeLine(s)).font(.caption).foregroundStyle(.secondary)
                Text(s.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)

                Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 1)

                // Two columns that fill the panel width — label left, value right within each half —
                // so the stats use the space instead of clustering on the left.
                VStack(spacing: 6) {
                    statPair("Size", humanSize(s.size), "Disk", pct(s.fractionOfTotal))
                    if s.isDir {
                        statPair("Files", s.subtreeFiles.formatted(), "Items", s.subtreeItems.formatted())
                    }
                    statPair("Modified", shortDate(s.modTime), "Created", shortDate(s.createTime))
                }
                if !s.isRoot { shareOfParent(s) }

                if !s.isRoot, let sel = selected {
                    HStack(spacing: 8) {
                        Button { model.reveal(sel) } label: { Label("Reveal", systemImage: "folder") }
                        Button { model.open(sel) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        Spacer()
                        Button(role: .destructive) { model.moveToTrash(sel); selected = nil } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .controlSize(.small).buttonStyle(.bordered).padding(.top, 3)
                }
            } else {
                Text("No selection").foregroundStyle(.tertiary).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func typeLine(_ s: NodeStats) -> String {
        if s.isDir { return s.isRoot ? "Scanned folder" : "Folder" }
        let desc = FilePalette.description(forExt: s.ext)
        return s.ext.isEmpty ? desc : "\(desc) · .\(s.ext)"
    }
    private func pct(_ f: Double) -> String { String(format: "%.1f%%", f * 100) }

    private func cell(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.caption).monospacedDigit()
        }
    }
    /// Two stat cells side by side, each filling half the row (value right-aligned in its half).
    private func statPair(_ l1: String, _ v1: String, _ l2: String, _ v2: String) -> some View {
        HStack(spacing: 18) {
            cell(l1, v1)
            cell(l2, v2)
        }
    }
    private func shareOfParent(_ s: NodeStats) -> some View {
        HStack(spacing: 5) {
            Text("Share of parent").font(.caption2).foregroundStyle(.secondary)
            Text(pct(s.fractionOfParent)).font(.caption).monospacedDigit()
            PercentBar(fraction: s.fractionOfParent).frame(width: 50, height: 6)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Legend (click a type to isolate it on the treemap)

struct LegendView: View {
    @ObservedObject var model: TreemapModel
    var body: some View {
        List {
            Section {
                ForEach(model.legend) { e in
                    let isHL = model.highlightExt == e.ext && !e.ext.hasPrefix("·")
                    let catColor = model.palette.color(FilePalette.category(forExt: e.ext.hasPrefix("·") ? "" : e.ext))
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(catColor).frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.displayExt).font(.callout).monospacedDigit().lineLimit(1)
                            Text(e.ext.hasPrefix("·") ? "\(e.count.formatted()) files" : FilePalette.description(forExt: e.ext))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .frame(width: 112, alignment: .leading)
                        // Type-colored proportion bar fills the middle (WinDirStat-style) — uses the
                        // space and gives an at-a-glance sense of each type's share.
                        PercentBar(fraction: e.fraction, color: catColor)
                            .frame(height: 6).frame(maxWidth: .infinity).layoutPriority(1)
                        if isHL { Image(systemName: "eye.fill").font(.caption2).foregroundStyle(.tint) }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(humanSize(e.bytes)).font(.caption).monospacedDigit()
                            Text(String(format: "%.1f%%", e.fraction * 100))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if e.ext.hasPrefix("·") { model.highlightExt = nil }
                        else { model.highlightExt = isHL ? nil : e.ext }
                    }
                    .listRowBackground(isHL ? Color.accentColor.opacity(0.18) : Color.clear)
                }
            } header: {
                HStack {
                    Text("File types — \(model.legend.count)")
                    Spacer()
                    if model.highlightExt != nil {
                        Button("Show all") { model.highlightExt = nil }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.tint)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)   // let the theme's canvas show through, like the tree
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
            .overlay(alignment: .topLeading) {
                if model.isFocused {
                    Button { model.clearTreemapFocus() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "scope")
                            Text(model.name(of: model.treemapRoot)).lineLimit(1)
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(8)
                    .help("Treemap is focused on this folder — click to return to the whole scan")
                }
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
    if model.isDir(node) {
        Button { model.focusTreemap(on: node) } label: { Label("Focus Treemap Here", systemImage: "scope") }
        Divider()
    }
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
