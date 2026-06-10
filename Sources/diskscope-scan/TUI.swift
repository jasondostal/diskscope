import Foundation
import Darwin
import DiskScopeCore

// An interactive terminal UI for DiskScope — another client of the same engine. A navigable
// directory list on the left, the cushioned treemap of the focused folder on the right
// (truecolor half-blocks, exactly like --term), drill in/out, live FSEvents refresh,
// warm-start snapshots, search, and SGR mouse support.
//
// Needs a truecolor terminal (iTerm2 / Ghostty / kitty / WezTerm) for the cushion to render.

// MARK: - Terminal lifecycle (raw mode + alt screen, restored on every exit path)

private var tuiOrigTermios = termios()
private var tuiResized: sig_atomic_t = 0
// Self-pipe: background threads write a byte to wake the main poll() out of its input wait
// (the old trick was a self-SIGWINCH, which conflated repaints with real resizes).
private var tuiWakeR: Int32 = -1
private var tuiWakeW: Int32 = -1

/// Restore cooked mode, leave the alternate screen, show the cursor. Safe to call twice.
private func tuiRestoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &tuiOrigTermios)
    // Mouse reporting OFF first — leftover click bytes in a cooked-mode shell are garbage input.
    let s = "\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h\u{1b}[?1049l"
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
    // Enter alt screen, hide cursor, enable mouse presses (1000) in SGR encoding (1006 —
    // the only mouse protocol whose coordinates don't clip at column 223).
    let s = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h"
    _ = s.withCString { write(STDOUT_FILENO, $0, strlen($0)) }

    // Restore on termination signals. Keyboard Ctrl-C is a byte (ISIG off) so it never
    // arrives as SIGINT, but a kill / hangup still must put the terminal back.
    signal(SIGTERM) { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGINT)  { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGHUP)  { _ in tuiRestoreTerminal(); _exit(0) }
    signal(SIGWINCH) { _ in tuiResized = 1 } // poll()/read() return EINTR → loop re-renders
}

private func tuiSize() -> (cols: Int, rows: Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return (Int(ws.ws_col), Int(ws.ws_row)) }
    return (100, 40)
}

/// Create the wakeup pipe. Both ends non-blocking: poke() must never stall a scan worker
/// on a full pipe, and the drain must never stall the UI on an empty one.
private func tuiInitWakePipe() {
    guard tuiWakeR < 0 else { return }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return } // no pipe → poke degrades to "repaint on next key"
    for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    tuiWakeR = fds[0]; tuiWakeW = fds[1]
}

// MARK: - Input

enum TUIKey: Equatable {
    case up, down, left, right, top, bottom, enter, back, refresh, trash, theme, open,
         ageToggle, ageDown, ageUp, depthToggle, search, sortToggle, quit, other
    case scrollUp, scrollDown                  // mouse wheel (SGR buttons 64 / 65)
    case mouse(x: Int, y: Int, button: Int)    // left press, 1-based terminal cell coords
}

/// Pure byte-sequence → key decode (escape sequences + vim/letter keys + SGR mouse). Kept
/// free of I/O so the mapping is obvious and could be unit-tested in isolation.
func decodeKey(_ b: [UInt8]) -> TUIKey {
    if b.isEmpty { return .other }
    // SGR mouse: ESC [ < button ; x ; y M (press) / m (release). Presses only — releases
    // and anything malformed fall through to .other.
    if b.count >= 4, b[0] == 0x1b, b[1] == 0x5b, b[2] == 0x3c {
        var nums = [0, 0, 0], ni = 0, i = 3
        while i < b.count {
            let c = b[i]
            if c >= 0x30, c <= 0x39 { nums[ni] = nums[ni] * 10 + Int(c - 0x30) }
            else if c == 0x3b { ni += 1; if ni > 2 { return .other } }
            else if c == 0x4d || c == 0x6d {                  // M / m terminator
                guard c == 0x4d, ni == 2 else { return .other } // press events only
                switch nums[0] {
                case 64: return .scrollUp
                case 65: return .scrollDown
                default:
                    // Low two bits: 0=left 1=middle 2=right; bit 5 set = motion (not subscribed).
                    if nums[0] & 0x23 == 0 { return .mouse(x: nums[1], y: nums[2], button: 0) }
                    return .other
                }
            } else { return .other }
            i += 1
        }
        return .other
    }
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
    case 0x2f:              return .search     // / — search prompt
    case 0x73:              return .sortToggle // s — cycle list sort
    case 0x1b:              return .back      // bare Esc → back / cancel
    default:                return .other
    }
}

/// Main-loop input: poll() on stdin AND the wake pipe, so a background poke() (FSEvents
/// repaint, invalidation flag) interrupts the wait without a fake signal. nil means
/// "nothing to decode, re-run the loop" — the loop re-renders if dirty. The modal readers
/// (readYes / readPath) stay plain blocking reads; they own the screen while active.
private func nextKey() -> TUIKey? {
    var pfds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
    if tuiWakeR >= 0 { pfds.append(pollfd(fd: tuiWakeR, events: Int16(POLLIN), revents: 0)) }
    let pr = poll(&pfds, nfds_t(pfds.count), -1)
    if pr < 0 { return nil }                               // EINTR (SIGWINCH) → re-render
    if pfds.count > 1, pfds[1].revents & Int16(POLLIN) != 0 {
        var junk = [UInt8](repeating: 0, count: 64)
        while read(tuiWakeR, &junk, junk.count) > 0 {}     // drain (non-blocking end)
        if pfds[0].revents & Int16(POLLIN) == 0 { return nil } // pure wakeup → repaint
    }
    // 64 bytes: enough for several SGR mouse reports; a lone keypress is 1–6 bytes.
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n == 0 { return .quit }   // EOF (stdin closed / not a terminal) — don't busy-loop
    if n < 0 { return nil }      // EINTR — let the loop re-render
    return decodeKey(Array(buf[0..<n]))
}

// MARK: - Progress plumbing (shared by the cold scan and in-TUI rescans)

/// Rate-limits progress redraws to ~10 Hz. onProgress fires from whichever scan worker
/// crosses the entry threshold, so the gate is locked.
final class TUIThrottle {
    private let lock = NSLock()
    private var last: UInt64 = 0
    func fire(intervalNs: UInt64 = 100_000_000) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last >= intervalNs else { return false }
        last = now
        return true
    }
}

private func tuiStderr(_ s: String) {
    FileHandle.standardError.write(s.data(using: .utf8)!)
}

private func tuiGB(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1e9)
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

/// The treemap of the focused folder as half-block text rows (two vertical pixels per
/// character cell). The TILES come from the caller — the TUI lays out once per frame and
/// keeps them for mouse hit-testing, so layout and pixels can't disagree.
private func cushionRows(_ index: FileIndex, tiles: [TreemapTile], width: Int, pxHeight H: Int,
                         palette: FilePalette.Palette, recency: FilePalette.RecencyShading,
                         depth: FilePalette.DepthShading, highlight: Int? = nil) -> [String] {
    guard width > 0, H >= 2 else { return [] }
    let now = Int64(Date().timeIntervalSince1970)
    let px = Treemap.renderCushionRGBA(tiles: tiles, width: width, height: H, ambient: palette.ambient) { tile in
        if tile.isDir { return palette.dirFill } // backdrop under too-small-to-draw files
        var c = recency.apply(palette.srgb(forExt: cliExt(index.nodes[tile.node].name)),
                              modTime: index.nodes[tile.node].modTime, now: now)
        c = depth.apply(c, depth: tile.depth)
        return c
    }

    // Selection: outline the selected folder's region, like the GUI. The layout emits a tile for
    // the folder node itself whose rect is the exact bounding box of its subtree. We stroke that
    // rectangle with thin box-drawing glyphs at CELL resolution (a solid pixel column would be a
    // whole terminal cell wide and read chunky); the glyph is a thin line, so the frame is crisp.
    // Border bounds in cell coords: x is 1 cell per pixel column; each cell row spans 2 px rows.
    var bx0 = -1, by0 = -1, bx1 = -1, by1 = -1
    if let h = highlight, let tile = tiles.first(where: { $0.node == h }) {
        let r = tile.rect
        bx0 = max(0, Int(r.x.rounded(.down)))
        bx1 = min(width - 1, Int((r.x + r.w).rounded(.up)) - 1)
        by0 = max(0, Int(r.y.rounded(.down)) / 2)
        by1 = min((H / 2) - 1, (Int((r.y + r.h).rounded(.up)) - 1) / 2)
    }

    var lines: [String] = []
    var y = 0, cellRow = 0
    while y + 1 < H {
        var s = ""
        for x in 0..<width {
            let t = (y * width + x) * 4, b = ((y + 1) * width + x) * 4
            let onTopBot = (cellRow == by0 || cellRow == by1) && x >= bx0 && x <= bx1
            let onSides  = (x == bx0 || x == bx1) && cellRow >= by0 && cellRow <= by1
            if bx0 >= 0, onTopBot || onSides {
                // White line glyph over the cell's color, so the border sits on top of content.
                let top = cellRow == by0, bot = cellRow == by1, lft = x == bx0, rgt = x == bx1
                let g: String
                if      top && lft { g = "┌" } else if top && rgt { g = "┐" }
                else if bot && lft { g = "└" } else if bot && rgt { g = "┘" }
                else if top || bot { g = "─" } else { g = "│" }
                s += "\u{1b}[38;2;255;255;255m\u{1b}[48;2;\(px[b]);\(px[b+1]);\(px[b+2])m\(g)"
            } else {
                s += "\u{1b}[38;2;\(px[t]);\(px[t+1]);\(px[t+2])m\u{1b}[48;2;\(px[b]);\(px[b+1]);\(px[b+2])m▀"
            }
        }
        s += "\u{1b}[0m"
        lines.append(s)
        y += 2
        cellRow += 1
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
    private var kids: [Int] = []        // cur's children, ordered per sortMode
    private var sel = 0                 // index into kids
    private var top = 0                 // scroll offset into kids
    private var dirty = true
    private var watcher: FSEventsWatcher?
    private let stateLock = NSLock()    // guards index/kids vs the FSEvents queue
    private var confirmMessage: String? // when set, shown in the footer (e.g. trash confirm)
    private var needsFullRescan = false // set by watcher.onInvalidated; the MAIN loop acts on it
    private var preScanEventID: UInt64  // journal cursor the index is known current to (warm-start save)
    private var sortMode: SortMode      // left-list order: size → name → modified ('s' cycles)

    // Search results mode ('/'). While searchQuery != nil the left pane lists results; the
    // right pane keeps showing cur's treemap.
    private var searchQuery: String?
    private var searchResults: [SearchResult] = []
    private var searchSel = 0
    private var searchTop = 0

    // Last rendered treemap layout + pane geometry, for mouse hit-testing. Main-thread only
    // (render and input both run there); clicks bounds-check against these because the
    // terminal can resize between a render and the click that aimed at it.
    private var lastTiles: [TreemapTile] = []
    private var lastMapW = 0, lastMapH = 0      // treemap pixel dimensions
    private var lastLeftW = 0, lastBodyRows = 0 // pane geometry in cells

    private enum SortMode: String, CaseIterable {
        case size, name, modified
        var next: SortMode { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
    }

    init(index: FileIndex, rootPath: String, theme: FilePalette.Theme, preScanEventID: UInt64) {
        self.index = index
        self.rootPath = rootPath
        self.palette = theme.palette
        self.themeID = theme.id
        self.recency = TUI.loadRecency()
        self.depth = TUI.loadDepth()
        self.preScanEventID = preScanEventID
        self.sortMode = TUI.loadSort()
        tuiInitWakePipe()
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
    private func persistSort() {
        UserDefaults.standard.set(sortMode.rawValue, forKey: "diskscope.tui.sort")
    }
    private static func loadSort() -> SortMode {
        SortMode(rawValue: UserDefaults.standard.string(forKey: "diskscope.tui.sort") ?? "") ?? .size
    }

    private func refreshKids() {
        let c = index.children(of: cur)
        switch sortMode {
        case .size:     kids = c.sorted { sizeOf($0) > sizeOf($1) }
        case .name:     kids = c.sorted { index.nodes[$0].name.localizedCaseInsensitiveCompare(index.nodes[$1].name) == .orderedAscending }
        case .modified: kids = c.sorted { index.nodes[$0].modTime > index.nodes[$1].modTime } // newest first
        }
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
            // FSEvents invalidation (journal wrapped / rescan-at-root) is flagged off-main and
            // serviced HERE: rescan() tears down the watcher, which would deadlock if attempted
            // from the watcher's own queue.
            stateLock.lock()
            let mustRescan = needsFullRescan; needsFullRescan = false
            stateLock.unlock()
            if mustRescan { rescan(to: rootPath) }
            if dirty { render(); dirty = false }
            guard let key = nextKey() else { continue }      // EINTR / pipe wake → re-render
            if searchQuery != nil { handleSearchKey(key); continue } // results mode owns the keys
            if key == .quit { break loop }
            if key == .trash { handleTrash(); dirty = true; continue } // modal: handles its own IO
            if key == .theme { pickTheme(); dirty = true; continue }   // modal
            if key == .open  { openFolder(); dirty = true; continue }  // modal
            if key == .search { startSearch(); dirty = true; continue } // modal prompt → results mode
            stateLock.lock()
            switch key {
            case .up:    if sel > 0 { sel -= 1 }
            case .down:  if sel < kids.count - 1 { sel += 1 }
            case .top:    sel = 0
            case .bottom: sel = max(0, kids.count - 1)
            case .scrollUp:   sel = max(0, sel - 3)                       // wheel: 3 rows/tick
            case .scrollDown: sel = min(max(0, kids.count - 1), sel + 3)
            case .enter, .right: descend()
            case .left, .back:   ascend()
            case .refresh: reconcileVisible()
            case .ageToggle: recency.enabled.toggle(); persistRecency()
            case .ageDown:   recency.strength = max(0.0, recency.strength - 0.1); persistRecency()
            case .ageUp:     recency.strength = min(1.0, recency.strength + 0.1); persistRecency()
            case .depthToggle: depth.enabled.toggle(); persistDepth()
            case .sortToggle: sortMode = sortMode.next; persistSort(); refreshKids()
            case .mouse(let x, let y, _): handleMouse(x: x, y: y)
            case .quit, .trash, .theme, .open, .search, .other: break
            }
            dirty = true
            stateLock.unlock()
        }
    }

    /// Persist the warm-start snapshot. Called once after run() returns (quit path) — and the
    /// equivalent inline save happens in rescan() for the outgoing root. If the live watcher is
    /// running the index is current to "now"; otherwise it's only good to the pre-scan cursor.
    func saveSnapshot() {
        stateLock.lock(); defer { stateLock.unlock() }
        let id = watcher != nil ? FSEventsWatcher.currentEventId() : preScanEventID
        WarmStart.save(index, root: rootPath, eventID: id)
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
        // reconcile() patches subtree totals up the ancestor chain itself — no aggregate() needed.
        index.reconcile(directoryPath: parentPath)
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
            guard let k = nextKey() else { continue }   // EINTR / wake → redraw
            switch k {
            case .up:     if pick > 0 { pick -= 1 }
            case .down:   if pick < themes.count - 1 { pick += 1 }
            case .scrollUp:   pick = max(0, pick - 3)
            case .scrollDown: pick = min(themes.count - 1, pick + 3)
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

    /// A minimal one-line text field on the bottom row (also the '/' search prompt). Enter
    /// submits, Esc / empty cancels, Backspace edits. Returns nil on cancel.
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
    /// The index build is synchronous (a second or two on a big tree); the bar shows live
    /// progress. The outgoing index is snapshotted first so its warm start survives the switch.
    private func rescan(to path: String) {
        drawInputBar("Indexing \(path)…")
        stateLock.lock()
        // Snapshot the OUTGOING index: the live watcher kept it current, so "now" is its honest
        // journal cursor (events racing the save just re-replay next launch; reconcile is
        // idempotent). Best-effort — a failed save only means a cold scan later.
        WarmStart.save(index, root: rootPath,
                       eventID: watcher != nil ? FSEventsWatcher.currentEventId() : preScanEventID)
        watcher?.stop(); watcher = nil
        var rbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let root = realpath(path, &rbuf) != nil ? String(cString: rbuf) : path
        // Capture BEFORE the build: anything that changes mid-scan replays on next warm start.
        preScanEventID = FSEventsWatcher.currentEventId()
        let throttle = TUIThrottle()
        let fresh = ParallelIndexBuilder.build(root: root) { [weak self] count, bytes in
            // Off-main, but the main thread is parked inside build() and a single throttled
            // write() to the tty is atomic enough for a status bar — no marshalling needed.
            guard throttle.fire() else { return }
            self?.drawInputBar("Indexing \(root)… \(count.formatted()) items · \(tuiGB(bytes))")
        }
        fresh.aggregate()
        index = fresh
        rootPath = root
        cur = 0; sel = 0; top = 0
        searchQuery = nil; searchResults = [] // old results index into the discarded arena
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

    // MARK: Search ('/' → prompt → results mode)

    /// Prompt for a query; non-empty Enter switches the left pane into results mode.
    private func startSearch() {
        guard let q = readPath(prompt: "Search: "), !q.isEmpty else { return }
        stateLock.lock()
        searchResults = index.search(q, limit: 500).sorted { $0.size > $1.size }
        searchQuery = q
        searchSel = 0; searchTop = 0
        stateLock.unlock()
    }

    /// Key handling while results are shown: navigate, Enter jumps to the result's parent
    /// folder with the result selected, Esc/q leaves the list without moving.
    private func handleSearchKey(_ key: TUIKey) {
        stateLock.lock()
        switch key {
        case .up:   if searchSel > 0 { searchSel -= 1 }
        case .down: if searchSel < searchResults.count - 1 { searchSel += 1 }
        case .top:    searchSel = 0
        case .bottom: searchSel = max(0, searchResults.count - 1)
        case .scrollUp:   searchSel = max(0, searchSel - 3)
        case .scrollDown: searchSel = min(max(0, searchResults.count - 1), searchSel + 3)
        case .enter, .right: jumpToResult()
        case .back, .left, .quit: searchQuery = nil; searchResults = []
        case .mouse(let x, let y, _):
            // Left pane only: click selects the result row; clicking the selected row jumps.
            if x <= lastLeftW, y >= 2, y < 2 + lastBodyRows {
                let li = searchTop + (y - 2)
                if li >= 0, li < searchResults.count {
                    if li == searchSel { jumpToResult() } else { searchSel = li }
                }
            }
        default: break
        }
        dirty = true
        stateLock.unlock()
    }

    /// Focus the selected result: cur ← its parent directory, cursor on the result's row.
    /// Caller holds stateLock.
    private func jumpToResult() {
        defer { searchQuery = nil; searchResults = [] }
        guard searchSel < searchResults.count else { return }
        let r = searchResults[searchSel]
        guard r.node < index.nodes.count, !index.nodes[r.node].deleted else { return } // raced a reconcile
        let parent = Int(index.nodes[r.node].parent)
        guard parent >= 0 else { return } // the root itself — nowhere to jump
        cur = parent; top = 0
        refreshKids()
        sel = kids.firstIndex(of: r.node) ?? 0
    }

    // MARK: Mouse (normal mode; called under stateLock)

    /// Left click: in the left pane, select the row (clicking the selected row descends);
    /// in the right pane, hit-test the treemap and select the clicked tile's top-level row.
    /// Everything bounds-checks against the LAST RENDERED geometry — a resize between render
    /// and click must degrade to a no-op, never an out-of-range index.
    private func handleMouse(x: Int, y: Int) {
        guard y >= 2, y < 2 + lastBodyRows else { return } // body rows: terminal rows 2…1+body
        if x <= lastLeftW {
            let li = top + (y - 2)
            guard li >= 0, li < kids.count else { return }
            if li == sel { descend() } else { sel = li }
        } else if x >= lastLeftW + 2 { // x == lastLeftW+1 is the separator column
            // Cell → treemap pixel: pane starts at column lastLeftW+2; each cell row is 2 px tall.
            let px = x - lastLeftW - 2
            let py = (y - 2) * 2
            guard px >= 0, px < lastMapW, py >= 0, py < lastMapH else { return }
            let fx = Double(px) + 0.5, fy = Double(py) + 0.5
            // Deepest tile under the point: tiles are parent-before-child, so the last hit wins.
            // Prefer a file tile; fall back to a backdrop dir (a region of too-small files).
            var hitFile = -1, hitDir = -1
            for t in lastTiles {
                guard fx >= t.rect.x, fx < t.rect.x + t.rect.w,
                      fy >= t.rect.y, fy < t.rect.y + t.rect.h else { continue }
                if t.isDir { if t.node != cur { hitDir = t.node } } else { hitFile = t.node }
            }
            var node = hitFile >= 0 ? hitFile : hitDir
            guard node >= 0, node != cur, node < index.nodes.count else { return }
            // Walk up to the ancestor that is a direct child of cur (the row to select).
            while Int(index.nodes[node].parent) != cur {
                let p = Int(index.nodes[node].parent)
                if p < 0 { return } // stale tiles (cur changed since render) — ignore the click
                node = p
            }
            if let i = kids.firstIndex(of: node) { sel = i }
        }
    }

    // MARK: Live refresh

    private func startWatching() {
        let w = FSEventsWatcher(roots: [rootPath]) { [weak self] dirs, deep in
            guard let self else { return }
            self.stateLock.lock()
            var changed = false
            // `deep` entries are "must scan subdirs" — re-graft the whole subtree; the rest
            // are single-level patches. Both fix ancestor totals themselves (no aggregate()).
            for d in dirs {
                let delta = deep.contains(d) ? self.index.reconcileSubtree(directoryPath: d)
                                             : self.index.reconcile(directoryPath: d)
                if delta.changed { changed = true }
            }
            if changed {
                self.refreshKids()
                self.dirty = true
            }
            self.stateLock.unlock()
            if changed { self.poke() }
        }
        w.onInvalidated = { [weak self] in
            guard let self else { return }
            // Journal unreliable (IDs wrapped / rescan at the root) — the index can't be
            // trusted. Flag + poke; the main loop performs the rescan (tearing this watcher
            // down from its own FSEvents queue would deadlock in FSEventStreamStop).
            self.stateLock.lock()
            self.needsFullRescan = true
            self.stateLock.unlock()
            self.poke()
        }
        if w.start() { watcher = w }
    }

    /// Reconcile the focused folder on demand (the 'r' key). reconcile() patches the ancestor
    /// totals itself, so no aggregate() follow-up.
    private func reconcileVisible() {
        if index.reconcile(directoryPath: index.path(of: cur)).changed {
            refreshKids()
        }
    }

    /// Wake the main loop's poll() so a background change repaints promptly: one byte down
    /// the self-pipe (drained in nextKey). Non-blocking write — a full pipe means a wake is
    /// already pending, which is all we need.
    private func poke() {
        guard tuiWakeW >= 0 else { return }
        var b: UInt8 = 1
        _ = write(tuiWakeW, &b, 1)
    }

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
        let inSearch = searchQuery != nil

        var out = "\u{1b}[H"                     // home (alt screen already cleared on entry)

        // Header: breadcrumb + totals (or the active search summary).
        let head: String
        if let q = searchQuery {
            head = " DiskScope  search: \"\(q)\" — \(searchResults.count) results"
        } else {
            let total = index.nodes.first?.totalSize ?? 0
            let crumb = index.path(of: cur)
            head = " DiskScope  " + ellipsizeFront(crumb, leftW + rightW - 28) +
                   "   \(tuiHuman(total)) · \(index.fileCount) files"
        }
        out += "\u{1b}[7m" + pad(head, cols) + "\u{1b}[0m\u{1b}[K\r\n"

        // Right pane: cushion treemap of the focused folder, with the selected child spotlit.
        // The TUI owns the layout call (not the row renderer) so the tiles + geometry can be
        // cached for mouse hit-testing against exactly what's on screen.
        let mapW = max(1, rightW)
        let mapH = max(2, bodyRows * 2)
        let tiles = Treemap.layout(index, root: cur, in: Rect(x: 0, y: 0, w: Double(mapW), h: Double(mapH)),
                                   minSide: 1, cushionHeight: 0.42)
        lastTiles = tiles
        lastMapW = mapW; lastMapH = mapH
        lastLeftW = leftW; lastBodyRows = bodyRows
        let highlight = (!inSearch && kids.indices.contains(sel)) ? kids[sel] : nil
        let map = cushionRows(index, tiles: tiles, width: mapW, pxHeight: mapH,
                              palette: palette, recency: recency, depth: depth, highlight: highlight)

        // Left pane: scrollable child list (or search results). Keep the selection in view.
        if inSearch {
            if searchSel < searchTop { searchTop = searchSel }
            if searchSel >= searchTop + bodyRows { searchTop = searchSel - bodyRows + 1 }
        } else {
            if sel < top { top = sel }
            if sel >= top + bodyRows { top = sel - bodyRows + 1 }
        }
        let curTotal = max(1, sizeOf(cur))

        for r in 0..<bodyRows {
            var left: String
            if inSearch {
                let li = searchTop + r
                left = li < searchResults.count ? searchRow(li, width: leftW, selected: li == searchSel)
                                                : pad("", leftW)
            } else {
                let li = top + r
                left = li < kids.count ? listRow(kids[li], width: leftW, selected: li == sel, parentTotal: curTotal)
                                       : pad("", leftW)
            }
            let right = r < map.count ? map[r] : pad("", rightW)
            out += left + "\u{1b}[0m│" + right + "\u{1b}[0m\u{1b}[K\r\n"
        }

        // Stats line: the selected entry's details (the "little window" of stats).
        out += statsLine(width: cols) + "\u{1b}[K\r\n"

        // Footer: a trash/other confirm prompt when pending, else key hints.
        if let cm = confirmMessage {
            out += "\u{1b}[48;2;130;95;30m\u{1b}[1m" + pad(" " + cm, cols) + "\u{1b}[0m\u{1b}[K"
        } else if inSearch {
            let hint = " ↑↓ move · Enter jump to result · g/G top/bottom · Esc/q back "
            out += "\u{1b}[7m" + pad(hint, cols) + "\u{1b}[0m\u{1b}[K"
        } else {
            let age = recency.enabled ? "a age \(Int((recency.strength * 100).rounded()))% −/+" : "a age"
            let dpt = depth.enabled ? "d depth on" : "d depth"
            let hint = " ↑↓ move · → in · ← up · / search · s sort:\(sortMode.rawValue) · o open · c theme · \(age) · \(dpt) · t trash · q quit "
            out += "\u{1b}[7m" + pad(hint, cols) + "\u{1b}[0m\u{1b}[K"
        }
        out += "\u{1b}[J" // clear anything below
        _ = out.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    }

    /// The selected entry's stats, as a full-width tinted bar: swatch · name · size · share of
    /// the current folder · (files/items for dirs) · modified date. In results mode: the
    /// selected result's full path (the list row only has room for an ellipsized parent).
    private func statsLine(width: Int) -> String {
        let bg = "\u{1b}[48;2;28;32;40m"
        if searchQuery != nil {
            guard searchSel < searchResults.count else {
                return bg + pad("  (no results)", width) + "\u{1b}[0m"
            }
            return bg + pad(" " + ellipsizeFront(searchResults[searchSel].path, max(4, width - 2)), width) + "\u{1b}[0m"
        }
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

        let suffixW = displayWidth(suffix)
        let nameAvail = max(4, width - suffixW - 3) // " " + glyph + " "
        let name = ellipsizeBack(n.name + (isDir ? "/" : ""), nameAvail)
        // Glyph resets only the FG (\e[39m) so the bar's background survives to the line end.
        let glyph = "\u{1b}[38;2;\(sr);\(sg);\(sb)m\(isDir ? "▸" : "·")\u{1b}[39m"
        let left = " \(glyph) \(name)"
        let leftVis = visibleWidth(left)
        let padCount = max(0, width - suffixW - leftVis)
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
                   (selected ? "\u{1b}[1m" : "") + padBack(name, nameW, visibleLen: displayWidth(name)) + (selected ? "\u{1b}[22m" : "") +
                   " " + padFront(sizeStr, 6) +
                   " \u{1b}[38;2;90;110;150m\(bar)\u{1b}[0m "
        let line = padBack(body, width, visibleLen: visibleWidth(body))
        return selected ? "\u{1b}[48;2;40;46;58m" + line + "\u{1b}[0m" : line
    }

    /// One results row: swatch · name · dimmed parent path (ellipsized from the front, like
    /// the breadcrumb) · size. Same visual language as listRow, no share bar (the share of
    /// WHAT would be ambiguous across folders).
    private func searchRow(_ li: Int, width: Int, selected: Bool) -> String {
        let r = searchResults[li]
        let (sr, sg, sb) = r.isDir ? (150, 150, 160) : rgb(palette.srgb(forExt: cliExt(r.name)))
        let swatch = "\u{1b}[38;2;\(sr);\(sg);\(sb)m\(r.isDir ? "▸" : "·")\u{1b}[0m"
        let sizeStr = tuiHuman(r.size)

        // " " swatch " " name " " path " " size(6) " " — name first-class, path takes the rest.
        let fixed = 1 + 1 + 1 + 1 + 1 + 6 + 1
        let avail = max(8, width - fixed)
        var name = r.name + (r.isDir ? "/" : "")
        let nameW = min(displayWidth(name), max(8, avail * 6 / 10))
        name = ellipsizeBack(name, nameW)
        let pathW = max(0, avail - nameW)
        let parent = (r.path as NSString).deletingLastPathComponent
        let pathStr = pathW > 1 ? ellipsizeFront(parent, pathW) : ""

        let body = " \(swatch) " +
                   (selected ? "\u{1b}[1m" : "") + padBack(name, nameW, visibleLen: displayWidth(name)) + (selected ? "\u{1b}[22m" : "") +
                   " \u{1b}[38;2;120;128;140m" + padBack(pathStr, pathW, visibleLen: displayWidth(pathStr)) + "\u{1b}[0m" +
                   " " + padFront(sizeStr, 6) + " "
        let line = padBack(body, width, visibleLen: visibleWidth(body))
        return selected ? "\u{1b}[48;2;40;46;58m" + line + "\u{1b}[0m" : line
    }
}

// MARK: - String/width helpers (ANSI-aware and wide-glyph-aware where it matters)

/// One-time LC_CTYPE init so wcwidth() classifies CJK/emoji as double-width — the default
/// "C" locale answers -1 for everything non-ASCII, which would defeat the whole point.
private let tuiWidthLocaleOnce: Void = { _ = setlocale(LC_CTYPE, "") }()

/// Terminal display columns for a string: CJK/emoji cells are 2 wide, combining marks 0.
/// wcwidth per scalar; unknown (-1) counts as 1 — same as the old Character-count behavior.
func displayWidth(_ s: String) -> Int {
    _ = tuiWidthLocaleOnce
    var w = 0
    for u in s.unicodeScalars {
        let c = wcwidth(wchar_t(u.value))
        w += c < 0 ? 1 : Int(c)
    }
    return w
}
private func displayWidth(_ ch: Character) -> Int { displayWidth(String(ch)) }

/// Longest prefix that fits in `w` columns (whole graphemes — never split a glyph).
private func truncToWidth(_ s: String, _ w: Int) -> (s: String, used: Int) {
    var out = "", used = 0
    for ch in s {
        let cw = displayWidth(ch)
        if used + cw > w { break }
        out.append(ch); used += cw
    }
    return (out, used)
}

private func ellipsizeBack(_ s: String, _ w: Int) -> String {
    if displayWidth(s) <= w { return s }
    if w <= 1 { return "…" }
    let (head, _) = truncToWidth(s, w - 1)
    return head + "…"
}
private func ellipsizeFront(_ s: String, _ w: Int) -> String {
    if displayWidth(s) <= w { return s }
    if w <= 1 { return "…" }
    // Accumulate from the tail until the column budget is spent (suffix by WIDTH, not count).
    var out: [Character] = []; var used = 0
    for ch in s.reversed() {
        let cw = displayWidth(ch)
        if used + cw > w - 1 { break }
        out.append(ch); used += cw
    }
    return "…" + String(out.reversed())
}
private func pad(_ s: String, _ w: Int) -> String {
    let n = displayWidth(s)
    if n < w { return s + String(repeating: " ", count: w - n) }
    if n == w { return s }
    let (head, used) = truncToWidth(s, w)
    // A double-width glyph cut at the edge leaves a 1-column hole — fill it with a space.
    return head + String(repeating: " ", count: w - used)
}
private func padBack(_ s: String, _ w: Int, visibleLen: Int? = nil) -> String {
    let n = visibleLen ?? displayWidth(s)
    return n >= w ? s : s + String(repeating: " ", count: w - n)
}
private func padFront(_ s: String, _ w: Int) -> String {
    let n = displayWidth(s)
    if n > w {
        // Keep the tail (sizes right-align), dropping leading glyphs until it fits.
        var out: [Character] = []; var used = 0
        for ch in s.reversed() {
            let cw = displayWidth(ch)
            if used + cw > w { break }
            out.append(ch); used += cw
        }
        return String(repeating: " ", count: w - used) + String(out.reversed())
    }
    return String(repeating: " ", count: w - n) + s
}
/// Count visible columns, skipping CSI escape sequences (so padding math ignores color codes).
private func visibleWidth(_ s: String) -> Int {
    var count = 0, inEsc = false
    for ch in s {
        if inEsc { if ch == "m" { inEsc = false }; continue }
        if ch == "\u{1b}" { inEsc = true; continue }
        count += displayWidth(ch)
    }
    return count
}

/// Entry point from main.swift: warm-start (snapshot + journal replay) or build the index
/// (parallel, with live progress), run the interactive UI, snapshot on the way out.
func runTUI(path rawPath: String, theme themeID: String? = nil) -> Never {
    var rbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let root = realpath(rawPath, &rbuf) != nil ? String(cString: rbuf) : rawPath
    // Resolve the theme from the shared Core library; unknown id falls back to the default,
    // with a heads-up on stderr (it scrolls away once the alt screen takes over).
    let theme: FilePalette.Theme
    if let id = themeID {
        if let t = FilePalette.theme(id: id) { theme = t }
        else {
            tuiStderr("unknown theme '\(id)'; using \(FilePalette.themePresets[0].name)\n")
            theme = FilePalette.themePresets[0]
        }
    } else if let saved = UserDefaults.standard.string(forKey: "diskscope.theme"),
              let t = FilePalette.theme(id: saved) {
        theme = t   // remembered from a prior in-TUI pick (the 'c' picker persists it)
    } else {
        theme = FilePalette.themePresets[0]
    }

    // Warm start: persisted snapshot + FSEvents journal replay. Falls back to a full scan on
    // any doubt. The pre-scan event ID is captured BEFORE scanning so the snapshot saved at
    // quit can only over-replay next launch (reconcile is idempotent), never miss changes.
    var eventID = FSEventsWatcher.currentEventId()
    let index: FileIndex
    if let warm = WarmStart.load(root: root) {
        index = warm.index   // arrives aggregated + reconciled
        tuiStderr("restored index (\(index.count.formatted()) entries, \(warm.replayedDirs) changes replayed) in \(String(format: "%.1f", warm.seconds))s\n")
    } else {
        eventID = FSEventsWatcher.currentEventId() // re-capture: load() may have burned seconds
        let throttle = TUIThrottle()
        tuiStderr("  indexing \(root)…")
        index = ParallelIndexBuilder.build(root: root) { count, bytes in
            // Off-main; a throttled atomic write() of one short line is all the marshalling
            // a \r status line needs.
            guard throttle.fire() else { return }
            tuiStderr("\r  indexing… \(count.formatted()) items · \(tuiGB(bytes))\u{1b}[K")
        }
        index.aggregate()
        tuiStderr("\r  indexed \(index.count.formatted()) items · \(tuiGB(index.nodes.first?.totalSize ?? 0))\u{1b}[K\n")
    }

    let tui = TUI(index: index, rootPath: root, theme: theme, preScanEventID: eventID)
    tui.run()
    // Persist the warm-start snapshot before exiting — synchronous on purpose: ~60MB worst
    // case writes fast, and a detached write could be killed mid-file by the exit.
    tui.saveSnapshot()
    exit(0)
}
