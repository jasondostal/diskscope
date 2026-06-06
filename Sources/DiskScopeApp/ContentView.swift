import SwiftUI
import AppKit
import DiskScopeCore

private let bg = Color(red: 0.043, green: 0.051, blue: 0.063) // #0b0d10

struct ContentView: View {
    @StateObject private var model = TreemapModel()
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
        .frame(minWidth: 720, minHeight: 480)
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
            TreemapCanvas(model: model, hover: $hover)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 52)).foregroundStyle(.tertiary)
            Text("Pick a folder to map").font(.title2).foregroundStyle(.secondary)
            HStack {
                Button("Choose Folder…") { chooseFolder() }.buttonStyle(.borderedProminent)
                Button("Scan Home") { model.scan(NSHomeDirectory()) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("DiskScope").font(.headline)
            if model.state == .ready {
                Text(model.path).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
                Text(humanSize(h.size)).monospacedDigit().foregroundStyle(.primary)
            } else {
                Text(model.state == .ready ? "Hover a cell to inspect" : " ").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout).padding(.horizontal, 14).padding(.vertical, 7)
        .frame(height: 30)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(url.path)
        }
    }
}

struct HoverInfo: Equatable {
    let node: Int
    let path: String
    let size: UInt64
}

struct TreemapCanvas: View {
    @ObservedObject var model: TreemapModel
    @Binding var hover: HoverInfo?

    var body: some View {
        GeometryReader { geo in
            let tiles = model.tiles(for: geo.size)
            Canvas { ctx, _ in
                // Leaves: cushioned gradient fill per file, with a consistent thin border
                // so adjacent same-category cells stay visually distinct (each file reads
                // as its own tile, not a merged block).
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
                // Top-level folder outlines for structure.
                for t in tiles where t.isDir && t.depth == 1 {
                    ctx.stroke(Path(cg(t.rect)), with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
                // Hover highlight.
                if let h = hover, let t = tiles.first(where: { $0.node == h.node }) {
                    ctx.stroke(Path(cg(t.rect)), with: .color(.white), lineWidth: 1.5)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    if let t = hitTest(tiles, pt), let info = model.info(for: t.node) {
                        hover = HoverInfo(node: t.node, path: info.path, size: info.size)
                    } else {
                        hover = nil
                    }
                case .ended:
                    hover = nil
                }
            }
        }
    }

    private func cg(_ r: Rect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: max(0, r.w), height: max(0, r.h))
    }

    /// Smallest leaf cell under the point (leaves tile the canvas without overlap).
    private func hitTest(_ tiles: [TreemapTile], _ p: CGPoint) -> TreemapTile? {
        tiles.last { !$0.isDir && cg($0.rect).contains(p) }
    }
}

/// Cushion gradient (lighter top → base bottom) for a file's category — the WinDirStat
/// 3D look, and it keeps same-category neighbors readable via the shading boundary.
func cushion(_ ext: String) -> (top: Color, bottom: Color) {
    let base = FilePalette.oklch(forExt: ext)
    return (oklchColor(base.lightened(0.07)), oklchColor(base.lightened(-0.05)))
}

func oklchColor(_ c: FilePalette.OKLCH) -> Color {
    let rgb = FilePalette.srgb(c)
    return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
}
