import SwiftUI
import AppKit
import QuickLook
import DiskScopeCore

let bg = Color(red: 0.043, green: 0.051, blue: 0.063) // #0b0d10

struct ContentView: View {
    @StateObject private var model = TreemapModel()
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var settings: SettingsStore
    @State private var selected: Int?
    @State private var hover: HoverInfo?
    @State private var hasFDA = true
    @State private var rightTab = 0   // inspector bottom: 0 = file types, 1 = reclaim
    // ⌘F search: a compact header field, debounced, with a floating results list.
    @State private var searchOpen = false
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var searchWork: DispatchWorkItem?
    @FocusState private var searchFocused: Bool
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
        .overlay(alignment: .topTrailing) { searchOverlay }
        .background(quickLookShortcut)
        .quickLookPreview($model.quickLookURL)
        .onChange(of: model.state) { _, s in
            if s != .ready { closeSearch() }   // a rescan invalidates result node ids
        }
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
            // WinDirStat's split: tree + inspector share the top row; the treemap spans
            // the FULL width below — never cut off. The inspector stays terse (see
            // DetailsView) so the legend/reclaim list gets the column's height.
            VSplitView {
                HSplitView {
                    TreeListView(model: model, selected: $selected)
                        .frame(minWidth: 320, minHeight: 140)
                    VStack(spacing: 0) {
                        DetailsView(model: model, selected: $selected)
                        Divider().overlay(Color.white.opacity(0.08))
                        // File-type legend or the reclaimable-space pane.
                        Picker("", selection: $rightTab) {
                            Text("File types").tag(0)
                            Text("Reclaim").tag(1)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        if rightTab == 0 {
                            LegendView(model: model)
                        } else {
                            ReclaimView(model: model, selected: $selected)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
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
                Text(statsLine)
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                if searchOpen {
                    TextField("Search files…", text: $searchText)
                        .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption)
                        .frame(width: 190)
                        .focused($searchFocused)
                        .onExitCommand { closeSearch() }   // Esc dismisses field + results
                        .onChange(of: searchText) { _, q in scheduleSearch(q) }
                }
                // File actions as clean borderless icons (matching the theme menu), tooltips for clarity.
                HStack(spacing: 12) {
                    Button { toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                        .help("Search files (⌘F)")
                        .keyboardShortcut("f")
                    // Explicit Refresh always means a REAL walk — skip the warm-start snapshot.
                    Button { model.scan(model.path, force: true) } label: { Image(systemName: "arrow.clockwise") }
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

    /// Header stats; a warm start advertises itself (and how much journal it replayed)
    /// so a near-instant "scan" doesn't read as a broken one.
    private var statsLine: String {
        var s = "\(humanSize(model.totalSize)) · \(model.fileCount.formatted()) files · \(String(format: "%.1fs", model.scanSeconds))"
        if let r = model.warmReplayedDirs { s += " · warm (\(r) replayed)" }
        return s
    }

    // MARK: - Search (⌘F)

    /// Floating results under the header's search field. An overlay, not a popover — a
    /// popover becomes the key window and steals focus from the field mid-typing.
    @ViewBuilder private var searchOverlay: some View {
        if searchOpen && !searchResults.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searchResults, id: \.node) { r in searchRow(r) }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 400)
            .frame(maxHeight: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .padding(.trailing, 14)
            .padding(.top, 42)   // just under the header row, near the field
        }
    }

    private func searchRow(_ r: SearchResult) -> some View {
        // Selecting keeps the list open for further picks; the tree's onChange handles
        // the reveal/scroll.
        Button { selected = r.node } label: {
            HStack(spacing: 8) {
                Image(systemName: r.isDir ? "folder.fill" : iconForExt(extOf(r.name)))
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(.caption).lineLimit(1)
                    Text(r.path).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(humanSize(r.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ~150ms debounce so a fast typist doesn't run a full-index search per keystroke.
    private func scheduleSearch(_ q: String) {
        searchWork?.cancel()
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { searchResults = []; return }   // cleared → results close
        let item = DispatchWorkItem { searchResults = model.search(needle) }
        searchWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func toggleSearch() {
        if searchOpen { closeSearch() }
        else {
            searchOpen = true
            DispatchQueue.main.async { searchFocused = true } // field must exist before focusing
        }
    }

    private func closeSearch() {
        searchWork?.cancel()
        searchOpen = false; searchText = ""; searchResults = []; searchFocused = false
    }

    // MARK: - Quick Look (Space)

    /// Hidden Space shortcut → Quick Look the selection. Not registered while the search
    /// field is focused, so typing a space stays a space.
    @ViewBuilder private var quickLookShortcut: some View {
        if !searchFocused {
            Button("") { if let sel = selected { model.quickLook(sel) } }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
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
                        // Flatten the expanded nodes into a single ForEach. A self-recursive row
                        // view (NodeRows-calls-NodeRows) is NOT reliably flattened by List past a
                        // couple of levels — it capped expansion at one level deep. Recursing in
                        // plain Swift and feeding List one flat list has no such limit.
                        ForEach(flattenedRows(root)) { row in
                            TreeRow(node: row.node, total: model.totalSize, depth: row.depth,
                                    isExpanded: expanded.contains(row.node.id), palette: model.palette) {
                                toggle(row.node.id)
                            }
                            .tag(row.node.id)
                            .id(row.node.id)
                            .contextMenu { fileMenu(model, row.node.id) }
                        }
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

extension TreeListView {
    /// One visible row: a node plus its indentation depth. Identified by the node id so List
    /// selection, `.tag`, and scroll-to-reveal all keep working.
    struct Row: Identifiable { let node: TreeNode; let depth: Int; var id: Int { node.id } }

    /// Depth-first walk of the expanded nodes, in display order. Children are still materialized
    /// lazily (only expanded branches touch `.children`), so a big tree stays cheap.
    func flattenedRows(_ root: TreeNode) -> [Row] {
        var rows: [Row] = []
        func walk(_ node: TreeNode, _ depth: Int) {
            rows.append(Row(node: node, depth: depth))
            if node.isDir, expanded.contains(node.id), let kids = node.children {
                for k in kids { walk(k, depth + 1) }
            }
        }
        walk(root, 0)
        return rows
    }

    func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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
        // No selection (or the root itself) would just repeat the header — name, path,
        // size, file count all live up there already. Collapse to a hint and give the
        // vertical space to the legend / reclaim pane below.
        if selected == nil || selected == 0 {
            Text("Click a tile or row to inspect")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            details
        }
    }

    private var details: some View {
        let s = model.stats(for: selected)
        return VStack(alignment: .leading, spacing: 5) {
            if let s {
                // Terse on purpose: the tree row already shows %, files, size, and
                // modified for the selection — repeating them here was the triplication.
                // Only what the tree CAN'T show lives here: full path, type, created,
                // item count, share-of-parent, and the actions.
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(s.isDir ? Color.secondary.opacity(0.5) : model.palette.color(s.category))
                        .frame(width: 13, height: 13)
                    Image(systemName: s.isDir ? "folder.fill" : iconForExt(s.ext))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(s.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(humanSize(s.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(s.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(metaLine(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if !s.isRoot {
                        Text(pct(s.fractionOfParent) + " of parent")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        PercentBar(fraction: s.fractionOfParent).frame(width: 44, height: 6)
                    }
                }

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
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// The not-in-the-tree facts on one line: type (files) or item count (dirs), + created.
    private func metaLine(_ s: NodeStats) -> String {
        var parts: [String] = []
        if s.isDir {
            parts.append("\(s.subtreeItems.formatted()) items")
        } else {
            let desc = FilePalette.description(forExt: s.ext)
            parts.append(s.ext.isEmpty ? desc : "\(desc) · .\(s.ext)")
        }
        if s.createTime > 0 { parts.append("created \(shortDate(s.createTime))") }
        return parts.joined(separator: " · ")
    }
    private func pct(_ f: Double) -> String { String(format: "%.1f%%", f * 100) }
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
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let tiles = model.tiles(for: geo.size)
            ZStack {
                // Cushioned, Phong-shaded leaves — a PIXEL-resolution bitmap displayed at
                // its native scale, so Retina shows crisp pillows instead of an upscale.
                if let img = model.cushionImage(for: geo.size, scale: displayScale) {
                    Image(decorative: img, scale: displayScale)
                        .resizable().frame(width: geo.size.width, height: geo.size.height)
                }
                // Overlays: structure + selection + hover outlines.
                Canvas { ctx, _ in
                    // Every folder outline, fading with depth — top-level partitions read
                    // strongest, deep nesting stays a whisper instead of a grid of noise.
                    // (depth 0 is the layout root: it's the whole canvas, skip it.)
                    for t in tiles where t.isDir && t.depth >= 1 {
                        let alpha = max(0.05, 0.22 - 0.05 * Double(t.depth - 1))
                        ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(alpha)), lineWidth: 1)
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
                    if let t = model.leafTile(at: pt), let info = model.info(for: t.node) {
                        hover = HoverInfo(node: t.node, path: info.path, size: info.size)
                    } else { hover = nil }
                case .ended: hover = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { ev in
                if let t = model.leafTile(at: ev.location) { selected = t.node }
            })
            // Double-click drills the treemap into the deepest folder under the cursor;
            // double-clicking when already focused on that exact folder toggles back out.
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { ev in
                guard let t = model.dirTile(at: ev.location) else { return }
                if t.node == model.treemapRoot { model.clearTreemapFocus() }
                else { model.focusTreemap(on: t.node) }
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
    Button { model.quickLook(node) } label: { Label("Quick Look", systemImage: "eye") }
    Divider()
    Button(role: .destructive) { model.moveToTrash(node) } label: { Label("Move to Trash", systemImage: "trash") }
}

func categoryColor(_ cat: FilePalette.Category) -> Color { oklchColor(FilePalette.oklch(cat)) }

func oklchColor(_ c: FilePalette.OKLCH) -> Color {
    let rgb = FilePalette.srgb(c)
    return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
}
