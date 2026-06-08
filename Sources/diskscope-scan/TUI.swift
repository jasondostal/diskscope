import Foundation
import Darwin
import DiskScopeCore

// An interactive terminal UI for DiskScope — another client of the same engine. A navigable
// directory list on the left, the cushioned treemap of the focused folder on the right
// (truecolor half-blocks, exactly like --term), drill in/out, live FSEvents refresh.
//
// Needs a truecolor terminal (iTerm2 / Ghostty / kitty / WezTerm) for the cushion to render.

// MARK: - Terminal lifecycle (raw mode + alt screen, restored on every exit path)

private var tuiOrigTermios = termios()
private var tuiResized: sig_atomic_t = 0

/// Restore cooked mode, leave the alternate screen, show the cursor. Safe to call twice.
private func tuiRestoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &tuiOrigTermios)
    let s = "\u{1b}[?25h\u{1b}[?1049l"
    _ = s.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
}

private func tuiEnterRawMode() {
    tcgetattr(STDIN_FILENO, &tuiOrigTermios)
    var raw = tuiOrigTermios
    // No echo, no line-buffering, no signal chars (we handle Ctrl-C as a byte), no flow control.
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
    raw.c_oflag &= ~tcflag_t(OPOST)
    // VMIN=1, VTIME=0: read() blocks until at least one byte, returns as soon as it has any.
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
            p[Int(VMIN)] = 1; p[Int(VTIME)] = 0
        }
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    // Enter alt screen, hide cursor.
    let s = "\u{1b}[?1049h\u{1b}[?25l"
    _ = s.withCString { write(STDOUT_FILENO, $0, strlen($0)) }

    // Restore on termination signals. Keyboard Ctrl-C is a byte (ISIG off) so it never
    // arrives as SIGINT, but a kill / hangup still must put the terminal back.
    signal(SIGTERM) { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGINT)  { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGHUP)  { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGWINCH) { _ in tuiResized = 1 } // read() returns EINTR → loop re-renders
}

private func tuiSize() -> (cols: Int, rows: Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return (Int(ws.ws_col), Int(ws.ws_row)) }
    return (100, 40)
}

// MARK: - Input

enum TUIKey: Equatable { case up, down, left, right, top, bottom, enter, back, refresh, trash, theme, open, ageToggle, ageDown, ageUp, depthToggle, quit, other }

/// Pure byte-sequence → key decode (escape sequences + vim/letter keys). Kept free of I/O
/// so the mapping is obvious and could be unit-tested in isolation.
func decodeKey(_ b: [UInt8]) -> TUIKey {
    if b.isEmpty { return .other }
    if b.count >= 3, b[0] == 0x1b, b[1] == 0x5b { // ESC [ …
        switch b[2] {
        case 0x41: return .up      // A
        case 0x42: return .down    // B
        case 0x43: return .right   // C
        case 0x44: return .left    // D
        case 0x48: return .top     // H (Home)
        case 0x46: return .bottom  // F (End)
        default:   return .other
        }
    }
    switch b[0] {
    case 0x71, 0x03:        return .quit    // q, Ctrl-C
    case 0x6b:              return .up      // k
    case 0x6a:              return .down    // j
    case 0x68:              return .left    // h
    case 0x6c:              return .right   // l
    case 0x0d, 0x0a:        return .enter   // Return
    case 0x7f, 0x08:        return .back    // Backspace
    case 0x67:              return .top     // g
    case 0x47:              return .bottom  // G
    case 0x72:              return .refresh // r
    case 0x74, 0x54:        return .trash   // t / T
    case 0x63:              return .theme     // c — theme picker
    case 0x6f, 0x4f:        return .open      // o / O — scan another folder
    case 0x61:              return .ageToggle // a — toggle recency shading
    case 0x2d:              return .ageDown   // - — weaker
    case 0x3d, 0x2b:        return .ageUp     // = / + — stronger
    case 0x64:              return .depthToggle // d — toggle depth shading
    case 0x1b:              return .back      // bare Esc → back / cancel
    default:                return .other
    }
}

private func nextKey() -> TUIKey? {
    var buf = [UInt8](repeating: 0, count: 8)
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n == 0 { return .quit }   // EOF (stdin closed / not a terminal) — don't busy-loop
    if n < 0 { return nil }      // EINTR (e.g. SIGWINCH) — let the loop re-render
    return decodeKey(Array(buf[0..<n]))
}

// MARK: - Rendering helpers

private func tuiHuman(_ bytes: UInt64) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(bytes), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v))B" : String(format: "%.1f%@", v, units[i])
}

private func rgb(_ c: (r: Double, g: Double, b: Double)) -> (Int, Int, Int) {
    func u(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
    return (u(c.r), u(c.g), u(c.b))
}

private let tuiDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()
private func tuiDate(_ epoch: Int64) -> String {
    guard epoch > 0 else { return "—" }
    return tuiDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

/// The treemap of `root` as half-block text rows (two vertical pixels per character cell).
/// Shared shape with --term; here it's composed into the right pane of the split view.
private func cushionRows(_ index: FileIndex, root: Int, width: Int, rows: Int,
                         palette: FilePalette.Palette, recency: FilePalette.RecencyShading,
                         depth: FilePalette.DepthShading, highlight: Int? = nil) -> [String] {
    guard width > 0, rows > 0 else { return [] }
    let H = max(2, rows * 2)
    let now = Int64(Date().timeIntervalSince1970)
    let tiles = Treemap.layout(index, root: root, in: Rect(x: 0, y: 0, w: Double(width), h: Double(H)),
                               minSide: 1, cushionHeight: 0.42)
    var px = Treemap.renderCushionRGBA(tiles: tiles, width: width, height: H, ambient: palette.ambient) { tile in
        var c = recency.apply(palette.srgb(forExt: cliExt(index.nodes[tile.node].name)),
                              modTime: index.nodes[tile.node].modTime, now: now)
        c = depth.apply(c, depth: tile.depth)
        return c
    }

    // Selection: trace a white border around the selected folder's region, like the GUI. The
    // layout emits a tile for the folder node itself, whose rect is the exact bounding box of
    // its whole subtree — so we just stroke that rectangle's perimeter in the pixel buffer.
    if let h = highlight, let tile = tiles.first(where: { $0.node == h }) {
        func setWhite(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < H else { return }
            let i = (y * width + x) * 4
            px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
        }
        let r = tile.rect
        let x0 = max(0, Int(r.x.rounded(.down)))
        let y0 = max(0, Int(r.y.rounded(.down)))
        let x1 = min(width - 1, Int((r.x + r.w).rounded(.up)) - 1)
        let y1 = min(H - 1, Int((r.y + r.h).rounded(.up)) - 1)
        if x1 >= x0, y1 >= y0 {
            for x in x0...x1 { setWhite(x, y0); setWhite(x, y1) }
            for y in y0...y1 { setWhite(x0, y); setWhite(x1, y) }
        }
    }
    var lines: [String] = []
    var y = 0
    while y + 1 < H {
        var s = ""
        for x in 0..<width {
            let t = (y * width + x) * 4, b = ((y + 1) * width + x) * 4
            s += "\u{1b}[38;2;\(px[t]);\(px[t+1]);\(px[t+2])m\u{1b}[48;2;\(px[b]);\(px[b+1]);\(px[b+2])m▀"
        }
        s += "\u{1b}[0m"
        lines.append(s)
        y += 2
    }
    return lines
}

// MARK: - The app

final class TUI {
    private var index: FileIndex
    private var rootPath: String
    private var palette: FilePalette.Palette   // active theme (shared with the GUI library)
    private var themeID: String                // current theme id (picker + persistence)
    private var recency: FilePalette.RecencyShading // optional age-shading layer (toggle with 'a')
    private var depth: FilePalette.DepthShading      // optional depth-shading layer (toggle with 'd')
    private var cur = 0                 // node of the folder currently shown
    private var kids: [Int] = []        // cur's children, largest first
    private var sel = 0                 // index into kids
    private var top = 0                 // scroll offset into kids
    private var dirty = true
    private var watcher: FSEventsWatcher?
    private let stateLock = NSLock()    // guards index/kids vs the FSEvents queue
    private var confirmMessage: String? // when set, shown in the footer (e.g. trash confirm)

    init(index: FileIndex, rootPath: String, theme: FilePalette.Theme) {
        self.index = index
        self.rootPath = rootPath
        self.palette = theme.palette
        self.themeID = theme.id
        self.recency = TUI.loadRecency()
        self.depth = TUI.loadDepth()
        refreshKids()
    }

    private func persistRecency() {
        let d = UserDefaults.standard
        d.set(recency.enabled, forKey: "diskscope.recency.enabled")
        d.set(recency.strength, forKey: "diskscope.recency.strength")
    }
    private static func loadRecency() -> FilePalette.RecencyShading {
        let d = UserDefaults.standard
        guard d.object(forKey: "diskscope.recency.enabled") != nil else { return FilePalette.RecencyShading() }
        return FilePalette.RecencyShading(enabled: d.bool(forKey: "diskscope.recency.enabled"),
                                          strength: d.double(forKey: "diskscope.recency.strength"))
    }
    private func persistDepth() {
        UserDefaults.standard.set(depth.enabled, forKey: "diskscope.depth.enabled")
        UserDefaults.standard.set(depth.strength, forKey: "diskscope.depth.strength")
    }
    private static func loadDepth() -> FilePalette.DepthShading {
        let d = UserDefaults.standard
        guard d.object(forKey: "diskscope.depth.enabled") != nil else { return FilePalette.DepthShading() }
        return FilePalette.DepthShading(enabled: d.bool(forKey: "diskscope.depth.enabled"),
                                        strength: d.double(forKey: "diskscope.depth.strength"))
    }

    private func refreshKids() {
        kids = index.children(of: cur)
            .sorted { sizeOf($0) > sizeOf($1) }
        sel = min(sel, max(0, kids.count - 1))
    }

    private func sizeOf(_ i: Int) -> UInt64 {
        let n = index.nodes[i]; return n.isDir ? n.totalSize : n.ownSize
    }

    func run() {
        tuiEnterRawMode()
        defer { tuiRestoreTerminal() }
        startWatching()
        loop: while true {
            if tuiResized != 0 { tuiResized = 0; dirty = true }
            if dirty { render(); dirty = false }
            guard let key = nextKey() else { continue }      // EINTR → re-render
            if key == .quit { break loop }
            if key == .trash { handleTrash(); dirty = true; continue } // modal: handles its own IO
            if key == .theme { pickTheme(); dirty = true; continue }   // modal
            if key == .open  { openFolder(); dirty = true; continue }  // modal
            stateLock.lock()
            switch key {
            case .up:    if sel > 0 { sel -= 1 }
            case .down:  if sel < kids.count - 1 { sel += 1 }
            case .top:    sel = 0
            case .bottom: sel = max(0, kids.count - 1)
            case .enter, .right: descend()
            case .left, .back:   ascend()
            case .refresh: reconcileVisible()
            case .ageToggle: recency.enabled.toggle(); persistRecency()
            case .ageDown:   recency.strength = max(0.0, recency.strength - 0.1); persistRecency()
            case .ageUp:     recency.strength = min(1.0, recency.strength + 0.1); persistRecency()
            case .depthToggle: depth.enabled.toggle(); persistDepth()
            case .quit, .trash, .theme, .open, .other: break
            }
            dirty = true
            stateLock.unlock()
        }
    }

    /// Move the selected entry to the Trash, with a y/N confirm. The modal read happens outside
    /// the state lock (so a background FSEvents reconcile can't block on the prompt); the index
    /// mutation re-acquires it.
    private func handleTrash() {
        stateLock.lock()
        guard sel < kids.count else { stateLock.unlock(); return }
        let node = kids[sel]
        let name = index.nodes[node].name
        let path = index.path(of: node)
        let parentPath = index.path(of: cur)
        stateLock.unlock()

        confirmMessage = "Move “\(name)” to Trash?   y = yes · any other key = cancel"
        render()
        guard readYes() else { confirmMessage = nil; return }
        confirmMessage = nil

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            confirmMessage = "Trash failed: \(error.localizedDescription)"
            render(); usleep(1_200_000); confirmMessage = nil
            return
        }
        stateLock.lock()
        index.reconcile(directoryPath: parentPath)
        index.aggregate()
        refreshKids()
        stateLock.unlock()
    }

    /// Blocking single-byte read for a y/N confirm. Returns true only on 'y'/'Y'.
    private func readYes() -> Bool {
        var b = [UInt8](repeating: 0, count: 1)
        while true {
            let n = read(STDIN_FILENO, &b, 1)
            if n == 1 { return b[0] == 0x79 || b[0] == 0x59 }
            if n == 0 { return false }       // EOF
            // n < 0 → EINTR (e.g. SIGWINCH); retry the read
        }
    }

    // MARK: Theme picker (interactive)

    /// Modal theme picker — a scrollable list of the shipped themes, each with a live swatch
    /// strip in its own colors. Enter applies + persists; q / Esc / ← cancels.
    private func pickTheme() {
        let themes = FilePalette.themePresets
        var pick = themes.firstIndex { $0.id == themeID } ?? 0
        while true {
            renderThemeMenu(themes, selected: pick)
            guard let k = nextKey() else { continue }   // EINTR → redraw
            switch k {
            case .up:     if pick > 0 { pick -= 1 }
            case .down:   if pick < themes.count - 1 { pick += 1 }
            case .top:    pick = 0
            case .bottom: pick = themes.count - 1
            case .enter, .right:
                themeID = themes[pick].id
                palette = themes[pick].palette
                UserDefaults.standard.set(themeID, forKey: "diskscope.theme")
                return
            case .back, .left, .quit:
                return
            default: break
            }
        }
    }

    private func renderThemeMenu(_ themes: [FilePalette.Theme], selected: Int) {
        let (cols, rows) = tuiSize()
        let listRows = max(1, rows - 2)
        var off = 0
        if selected >= listRows { off = selected - listRows + 1 }
        var out = "\u{1b}[H\u{1b}[2J\u{1b}[7m"
        out += pad("  Pick a theme   ↑↓ move · Enter apply · q cancel", cols) + "\u{1b}[0m\u{1b}[K\r\n"
        let preview = FilePalette.previewCategories
        for r in 0..<listRows {
            let i = off + r
            if i < themes.count {
                let t = themes[i]
                var swatch = ""
                for cat in preview {
                    let (sr, sg, sb) = rgb(t.palette.srgb(cat))
                    swatch += "\u{1b}[38;2;\(sr);\(sg);\(sb)m█\u{1b}[0m"
                }
                let line = " \(i == selected ? "▸" : " ") \(padBack(t.name, 14)) \(swatch)"
                let padded = padBack(line, cols, visibleLen: visibleWidth(line))
                out += (i == selected ? "\u{1b}[48;2;40;46;58m" + padded + "\u{1b}[0m" : padded)
            } else {
                out += pad("", cols)
            }
            out += "\u{1b}[K\r\n"
        }
        out += "\u{1b}[J"
        _ = out.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    }

    // MARK: Scan a different folder (interactive)

    /// Prompt for a path and rescan it in place. `~` is expanded; a non-folder shows an error.
    private func openFolder() {
        guard let input = readPath(prompt: "Scan folder: ") else { return }
        var path = input
        if path == "~" { path = NSHomeDirectory() }
        else if path.hasPrefix("~/") { path = NSHomeDirectory() + String(path.dropFirst()) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            confirmMessage = "Not a folder: \(path)"
            render(); usleep(1_400_000); confirmMessage = nil
            return
        }
        rescan(to: path)
    }

    /// A minimal one-line text field on the bottom row. Enter submits, Esc / empty cancels,
    /// Backspace edits. Returns nil on cancel.
    private func readPath(prompt: String) -> String? {
        var buf = ""
        while true {
            drawInputBar(prompt + buf)
            var b = [UInt8](repeating: 0, count: 16)
            let n = read(STDIN_FILENO, &b, b.count)
            if n == 0 { return nil }     // EOF
            if n < 0 { continue }        // EINTR (e.g. SIGWINCH) → redraw
            var i = 0
            while i < n {
                let c = b[i]
                if c == 0x0d || c == 0x0a { return buf.isEmpty ? nil : buf }  // Enter
                if c == 0x1b { return nil }                                   // Esc cancels
                if c == 0x7f || c == 0x08 { if !buf.isEmpty { buf.removeLast() } } // Backspace
                else if c >= 0x20 && c < 0x7f { buf.append(Character(UnicodeScalar(c))) }
                i += 1
            }
        }
    }

    private func drawInputBar(_ s: String) {
        let (cols, rows) = tuiSize()
        let bar = "\u{1b}[\(rows);1H\u{1b}[48;2;30;60;90m\u{1b}[1m" + pad(" " + s + "▏", cols) + "\u{1b}[0m"
        _ = bar.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    }

    /// Stop watching, rebuild the index for `path`, reset the view to its root, resume watching.
    /// The index build is synchronous (a second or two on a big tree); the bar shows progress.
    private func rescan(to path: String) {
        drawInputBar("Indexing \(path)…")
        stateLock.lock()
        watcher?.stop(); watcher = nil
        var rbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let root = realpath(path, &rbuf) != nil ? String(cString: rbuf) : path
        let fresh = ParallelIndexBuilder.build(root: root)
        fresh.aggregate()
        index = fresh
        rootPath = root
        cur = 0; sel = 0; top = 0
        refreshKids()
        stateLock.unlock()
        startWatching()
        dirty = true
    }

    private func descend() {
        guard sel < kids.count, index.nodes[kids[sel]].isDir else { return }
        cur = kids[sel]; sel = 0; top = 0
        refreshKids()
    }

    private func ascend() {
        let parent = Int(index.nodes[cur].parent)
        guard parent >= 0 else { return }
        let prev = cur
        cur = parent
        refreshKids()
        // Land the cursor back on the folder we came up from.
        if let i = kids.firstIndex(of: prev) { sel = i; top = 0 }
    }

    // MARK: Live refresh

    private func startWatching() {
        let w = FSEventsWatcher(roots: [rootPath]) { [weak self] dirs, _ in
            guard let self else { return }
            self.stateLock.lock()
            var changed = false
            for d in dirs where self.index.reconcile(directoryPath: d).changed { changed = true }
            if changed {
                self.index.aggregate()
                self.refreshKids()
                self.dirty = true
            }
            self.stateLock.unlock()
            if changed { self.poke() }
        }
        if w.start() { watcher = w }
    }

    /// Reconcile the focused folder on demand (the 'r' key).
    private func reconcileVisible() {
        if index.reconcile(directoryPath: index.path(of: cur)).changed {
            index.aggregate(); refreshKids()
        }
    }

    /// Nudge the blocked read() so a background FSEvents change repaints promptly. Writing a
    /// no-op escape to our own input isn't portable; instead we rely on the next keypress or a
    /// resize. To keep it live, push a harmless signal to interrupt read().
    private func poke() { kill(getpid(), SIGWINCH) }

    // MARK: Draw

    private func render() {
        let (cols, rows) = tuiSize()
        guard cols > 20, rows > 5 else {
            _ = "\u{1b}[H\u{1b}[2JTerminal too small".withCString { write(STDOUT_FILENO, $0, strlen($0)) }
            return
        }
        let bodyRows = rows - 3                 // minus header + stats line + footer
        let leftW = max(24, min(48, cols * 4 / 10))
        let rightW = cols - leftW - 1           // 1 col separator

        var out = "\u{1b}[H"                     // home (alt screen already cleared on entry)

        // Header: breadcrumb + totals.
        let total = index.nodes.first?.totalSize ?? 0
        let crumb = index.path(of: cur)
        let head = " DiskScope  " + ellipsizeFront(crumb, leftW + rightW - 28) +
                   "   \(tuiHuman(total)) · \(index.fileCount) files"
        out += "\u{1b}[7m" + pad(head, cols) + "\u{1b}[0m\u{1b}[K\r\n"

        // Right pane: cushion treemap of the focused folder, with the selected child spotlit.
        let mapRows = bodyRows
        let highlight = kids.indices.contains(sel) ? kids[sel] : nil
        let map = cushionRows(index, root: cur, width: max(1, rightW), rows: mapRows, palette: palette, recency: recency, depth: depth, highlight: highlight)

        // Left pane: scrollable child list. Keep the selection in view.
        if sel < top { top = sel }
        if sel >= top + bodyRows { top = sel - bodyRows + 1 }
        let curTotal = max(1, sizeOf(cur))

        for r in 0..<bodyRows {
            let li = top + r
            var left: String
            if li < kids.count {
                left = listRow(kids[li], width: leftW, selected: li == sel, parentTotal: curTotal)
            } else {
                left = pad("", leftW)
            }
            let right = r < map.count ? map[r] : pad("", rightW)
            out += left + "\u{1b}[0m│" + right + "\u{1b}[0m\u{1b}[K\r\n"
        }

        // Stats line: the selected entry's details (the "little window" of stats).
        out += statsLine(width: cols) + "\u{1b}[K\r\n"

        // Footer: a trash/other confirm prompt when pending, else key hints.
        if let cm = confirmMessage {
            out += "\u{1b}[48;2;130;95;30m\u{1b}[1m" + pad(" " + cm, cols) + "\u{1b}[0m\u{1b}[K"
        } else {
            let age = recency.enabled ? "a age \(Int((recency.strength * 100).rounded()))% −/+" : "a age"
            let dpt = depth.enabled ? "d depth on" : "d depth"
            let hint = " ↑↓ move · → in · ← up · o open · c theme · \(age) · \(dpt) · t trash · q quit "
            out += "\u{1b}[7m" + pad(hint, cols) + "\u{1b}[0m\u{1b}[K"
        }
        out += "\u{1b}[J" // clear anything below
        _ = out.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    }

    /// The selected entry's stats, as a full-width tinted bar: swatch · name · size · share of
    /// the current folder · (files/items for dirs) · modified date.
    private func statsLine(width: Int) -> String {
        let bg = "\u{1b}[48;2;28;32;40m"
        guard sel < kids.count else {
            return bg + pad("  (empty folder)", width) + "\u{1b}[0m"
        }
        let n = index.nodes[kids[sel]]
        let isDir = n.isDir
        let size = isDir ? n.totalSize : n.ownSize
        let pct = Double(size) / Double(max(1, sizeOf(cur))) * 100
        let (sr, sg, sb) = isDir ? (150, 150, 160) : rgb(palette.srgb(forExt: cliExt(n.name)))

        var suffix = "  \(tuiHuman(size)) · \(String(format: "%.1f", pct))%"
        if isDir { suffix += " · \(n.subtreeFiles) files · \(n.subtreeItems) items" }
        suffix += "  \(tuiDate(n.modTime)) "

        let nameAvail = max(4, width - suffix.count - 3) // " " + glyph + " "
        let name = ellipsizeBack(n.name + (isDir ? "/" : ""), nameAvail)
        // Glyph resets only the FG (\e[39m) so the bar's background survives to the line end.
        let glyph = "\u{1b}[38;2;\(sr);\(sg);\(sb)m\(isDir ? "▸" : "·")\u{1b}[39m"
        let left = " \(glyph) \(name)"
        let leftVis = visibleWidth(left)
        let padCount = max(0, width - suffix.count - leftVis)
        return bg + left + String(repeating: " ", count: padCount) + suffix + "\u{1b}[0m"
    }

    /// One left-pane row: color swatch · name · size · share-of-folder bar.
    private func listRow(_ node: Int, width: Int, selected: Bool, parentTotal: UInt64) -> String {
        let n = index.nodes[node]
        let isDir = n.isDir
        let size = isDir ? n.totalSize : n.ownSize
        let frac = Double(size) / Double(parentTotal)

        let (sr, sg, sb) = isDir ? (150, 150, 160) : rgb(palette.srgb(forExt: cliExt(n.name)))
        let swatch = "\u{1b}[38;2;\(sr);\(sg);\(sb)m\(isDir ? "▸" : "·")\u{1b}[0m"

        let sizeStr = tuiHuman(size)
        let barW = 6
        let filled = max(0, min(barW, Int((frac * Double(barW)).rounded())))
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: barW - filled)

        // name gets whatever's left after: " " swatch " " name " " size(6) " " bar(6) " "
        let fixed = 1 + 1 + 1 + 1 + 6 + 1 + barW + 1
        let nameW = max(4, width - fixed)
        var name = n.name
        if isDir { name += "/" }
        name = ellipsizeBack(name, nameW)

        let body = " \(swatch) " +
                   (selected ? "\u{1b}[1m" : "") + padBack(name, nameW) + (selected ? "\u{1b}[22m" : "") +
                   " " + padFront(sizeStr, 6) +
                   " \u{1b}[38;2;90;110;150m\(bar)\u{1b}[0m "
        let line = padBack(body, width, visibleLen: visibleWidth(body))
        return selected ? "\u{1b}[48;2;40;46;58m" + line + "\u{1b}[0m" : line
    }
}

// MARK: - String/width helpers (ANSI-aware where it matters)

private func ellipsizeBack(_ s: String, _ w: Int) -> String {
    if s.count <= w { return s }
    if w <= 1 { return "…" }
    return String(s.prefix(w - 1)) + "…"
}
private func ellipsizeFront(_ s: String, _ w: Int) -> String {
    if s.count <= w { return s }
    if w <= 1 { return "…" }
    return "…" + String(s.suffix(w - 1))
}
private func pad(_ s: String, _ w: Int) -> String {
    let n = s.count
    return n >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - n)
}
private func padBack(_ s: String, _ w: Int, visibleLen: Int? = nil) -> String {
    let n = visibleLen ?? s.count
    return n >= w ? s : s + String(repeating: " ", count: w - n)
}
private func padFront(_ s: String, _ w: Int) -> String {
    let n = s.count
    return n >= w ? String(s.suffix(w)) : String(repeating: " ", count: w - n) + s
}
/// Count visible columns, skipping CSI escape sequences (so padding math ignores color codes).
private func visibleWidth(_ s: String) -> Int {
    var count = 0, inEsc = false
    for ch in s {
        if inEsc { if ch == "m" { inEsc = false }; continue }
        if ch == "\u{1b}" { inEsc = true; continue }
        count += 1
    }
    return count
}

/// Entry point from main.swift: build the index (parallel) then run the interactive UI.
func runTUI(path rawPath: String, theme themeID: String? = nil) -> Never {
    var rbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let root = realpath(rawPath, &rbuf) != nil ? String(cString: rbuf) : rawPath
    // Resolve the theme from the shared Core library; unknown id falls back to the default,
    // with a heads-up on stderr (it scrolls away once the alt screen takes over).
    let theme: FilePalette.Theme
    if let id = themeID {
        if let t = FilePalette.theme(id: id) { theme = t }
        else {
            FileHandle.standardError.write("unknown theme '\(id)'; using \(FilePalette.themePresets[0].name)\n".data(using: .utf8)!)
            theme = FilePalette.themePresets[0]
        }
    } else if let saved = UserDefaults.standard.string(forKey: "diskscope.theme"),
              let t = FilePalette.theme(id: saved) {
        theme = t   // remembered from a prior in-TUI pick (the 'c' picker persists it)
    } else {
        theme = FilePalette.themePresets[0]
    }
    FileHandle.standardError.write("indexing \(root)…\n".data(using: .utf8)!)
    let index = ParallelIndexBuilder.build(root: root)
    index.aggregate()
    TUI(index: index, rootPath: root, theme: theme).run()
    exit(0)
}
