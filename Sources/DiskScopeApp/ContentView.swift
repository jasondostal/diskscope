import SwiftUI
import AppKit
import DiskScopeCore

let bg = Color(red: 0.043, green: 0.051, blue: 0.063) // #0b0d10

struct ContentView: View {
    @StateObject private var model = TreemapModel()
    @State private var selected: Int?
    @State private var hover: HoverInfo?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(bg)
        .frame(minWidth: 860, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            emptyState
        case .scanning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Scanning \(model.path)…").foregroundStyle(.secondary)
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

    var body: some View {
        if let root = model.makeRootNode() {
            List(selection: $selected) {
                OutlineGroup([root], children: \.children) { node in
                    TreeRow(node: node, total: model.totalSize).tag(node.id)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
        } else {
            Color.clear
        }
    }
}

struct TreeRow: View {
    let node: TreeNode
    let total: UInt64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDir ? "folder.fill" : "doc")
                .font(.caption2)
                .foregroundStyle(node.isDir ? Color.secondary : Color(.tertiaryLabelColor))
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            PercentBar(fraction: total > 0 ? Double(node.size) / Double(total) : 0)
                .frame(width: 52, height: 7)
            Text(humanSize(node.size))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
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
            Section("File types") {
                ForEach(model.legend, id: \.cat) { entry in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(categoryColor(entry.cat))
                            .frame(width: 12, height: 12)
                        Text(entry.cat.rawValue.capitalized)
                        Spacer()
                        Text(humanSize(entry.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
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
            Canvas { ctx, _ in
                for t in tiles where !t.isDir {
                    let r = cg(t.rect)
                    let (top, bottom) = cushion(model.ext(of: t.node))
                    ctx.fill(Path(r), with: .linearGradient(
                        Gradient(colors: [top, bottom]),
                        startPoint: CGPoint(x: r.minX, y: r.minY),
                        endPoint: CGPoint(x: r.minX, y: r.maxY)))
                    if t.rect.w > 3, t.rect.h > 3 {
                        ctx.stroke(Path(r), with: .color(bg.opacity(0.55)), lineWidth: 0.5)
                    }
                }
                for t in tiles where t.isDir && t.depth == 1 {
                    ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
                // Selection (from tree or treemap click) — bold outline of the region.
                if let sel = selected, let t = tiles.first(where: { $0.node == sel }) {
                    ctx.stroke(Path(cg(t.rect)), with: .color(.white), lineWidth: 2)
                }
                // Hover highlight.
                if let h = hover, h.node != selected, let t = tiles.first(where: { $0.node == h.node }) {
                    ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(0.6)), lineWidth: 1)
                }
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
        }
    }

    private func cg(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: max(0, r.w), height: max(0, r.h)) }

    private func hitTest(_ tiles: [TreemapTile], _ p: CGPoint) -> TreemapTile? {
        tiles.last { !$0.isDir && cg($0.rect).contains(p) }
    }
}

// MARK: - Color helpers

func cushion(_ ext: String) -> (top: Color, bottom: Color) {
    let base = FilePalette.oklch(forExt: ext)
    return (oklchColor(base.lightened(0.07)), oklchColor(base.lightened(-0.05)))
}

func categoryColor(_ cat: FilePalette.Category) -> Color { oklchColor(FilePalette.oklch(cat)) }

func oklchColor(_ c: FilePalette.OKLCH) -> Color {
    let rgb = FilePalette.srgb(c)
    return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
}
