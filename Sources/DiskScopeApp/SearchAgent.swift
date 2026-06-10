import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import DiskScopeCore

// The Everything layer: an always-on multi-volume SearchService, a ⌥Space global hotkey,
// and a Spotlight-style floating panel. The app window is just ONE client of the engine —
// closing it drops DiskScope to a menu-bar item; the index and hotkey live on.

/// Selectable global-hotkey combos (a full key recorder is a later nicety; presets cover
/// the conflicts — e.g. rill already owns ⌥Space on this machine).
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optSpace, ctrlSpace, ctrlOptSpace, cmdShiftSpace, disabled
    var id: String { rawValue }

    var label: String {
        switch self {
        case .optSpace:      return "⌥ Space"
        case .ctrlSpace:     return "⌃ Space"
        case .ctrlOptSpace:  return "⌃⌥ Space"
        case .cmdShiftSpace: return "⇧⌘ Space"
        case .disabled:      return "Disabled"
        }
    }

    var carbon: (key: UInt32, mods: UInt32)? {
        switch self {
        case .optSpace:      return (UInt32(kVK_Space), UInt32(optionKey))
        case .ctrlSpace:     return (UInt32(kVK_Space), UInt32(controlKey))
        case .ctrlOptSpace:  return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .cmdShiftSpace: return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .disabled:      return nil
        }
    }
}

/// App-lifetime owner of the search engine + hotkey + panel. A singleton so the SwiftUI
/// scenes and the NSApplicationDelegate can share it without plumbing.
final class SearchAgent: ObservableObject {
    static let shared = SearchAgent()

    let service = SearchService()
    @Published var volumes: [SearchService.VolumeInfo] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hotKeyPreset: HotKeyPreset {
        didSet {
            UserDefaults.standard.set(hotKeyPreset.rawValue, forKey: "diskscope.hotkey")
            registerHotKey()
        }
    }

    private var hotKey: GlobalHotKey?
    private var panel: SearchPanelController?
    private init() {
        hotKeyPreset = HotKeyPreset(rawValue:
            UserDefaults.standard.string(forKey: "diskscope.hotkey") ?? "") ?? .optSpace
    }

    private func registerHotKey() {
        hotKey = nil // unregister the old combo first (deinit)
        guard let c = hotKeyPreset.carbon else { return }
        hotKey = GlobalHotKey(keyCode: c.key, modifiers: c.mods) { [weak self] in self?.togglePanel() }
    }

    func start() {
        guard panel == nil else { return }
        panel = SearchPanelController(service: service)
        registerHotKey()
        service.onChange = { [weak self] in self?.volumes = $0 }
        service.start()

        // Track mounts live: a plugged-in local volume gets indexed (warm if it's been
        // seen before), an unplugged one drops out of the namespace.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            if SearchService.localVolumeRoots().contains(url.path) {
                self?.service.addVolume(root: url.path)
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.service.removeVolume(root: url.path)
        }
    }

    func togglePanel() { panel?.toggle() }

    func setLaunchAtLogin(_ on: Bool) {
        // SMAppService needs a real bundle; from a bare `swift run` binary this throws —
        // harmless, the toggle just stays off.
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func saveAll() { service.saveAll() }
}

// MARK: - Global hotkey (⌥Space)

/// Carbon RegisterEventHotKey — still the sanctioned no-permissions way to own a global
/// hotkey (NSEvent global monitors need Accessibility and can't consume the keystroke).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
          action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef) == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4453_4B50) /* "DSKP" */, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Floating panel

/// Borderless panels refuse key status by default; the search field needs it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Bumped each time the panel shows — the SwiftUI view watches it to reset + refocus.
final class PanelSession: ObservableObject {
    @Published var token = 0
}

/// Spotlight-shaped: non-activating (your current app keeps focus), floats over
/// everything, hides on Esc or losing key status.
final class SearchPanelController {
    private let panel: KeyablePanel
    private let session = PanelSession()
    private var resignObserver: Any?

    init(service: SearchService) {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = SearchPanelView(service: service, session: session) { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: view)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.hide() }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let s = panel.frame.size
            // Spotlight altitude: centered, upper third.
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2,
                                         y: f.minY + f.height * 0.6 - s.height / 2))
        }
        session.token += 1
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Panel UI

struct SearchPanelView: View {
    let service: SearchService
    @ObservedObject var session: PanelSession
    let dismiss: () -> Void

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var sel = 0
    @State private var work: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Search everywhere…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { reveal(sel) }
                    .onKeyPress(.downArrow) { sel = min(sel + 1, max(0, results.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { sel = max(0, sel - 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onKeyPress { press in
                        if press.key == .return, press.modifiers.contains(.command) {
                            open(sel); return .handled
                        }
                        return .ignored
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Color.white.opacity(0.08))

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "Type to search every indexed volume" : "No matches")
                        .font(.callout).foregroundStyle(.secondary)
                    if query.isEmpty {
                        Text("filters: ext:swift · size:>1gb · size:<10mb · kind:folder · path:working")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                                row(r, highlighted: i == sel)
                                    .id(i)
                                    .onTapGesture { sel = i; reveal(i) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: sel) { _, i in proxy.scrollTo(i) }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text("↩ Reveal in Finder · ⌘↩ Open · esc Close")
                Spacer()
                Text(results.isEmpty ? "" : "\(results.count) results")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 7)
        }
        .frame(width: 660, height: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .onChange(of: query) { _, q in schedule(q) }
        .onChange(of: session.token) { _, _ in
            query = ""; results = []; sel = 0
            DispatchQueue.main.async { focused = true }
        }
    }

    private func row(_ r: SearchResult, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.isDir ? "folder.fill" : iconForExt(extOf(r.name)))
                .font(.callout).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.callout).lineLimit(1)
                Text(r.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(humanSize(r.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(highlighted ? Color.accentColor.opacity(0.25) : .clear)
    }

    /// Queries are ~ms; 20ms just coalesces a typing burst.
    private func schedule(_ q: String) {
        work?.cancel()
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { results = []; sel = 0; return }
        let item = DispatchWorkItem {
            results = service.search(needle, limit: 60)
            sel = 0
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    private func reveal(_ i: Int) {
        guard results.indices.contains(i) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: results[i].path)])
        dismiss()
    }

    private func open(_ i: Int) {
        guard results.indices.contains(i) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: results[i].path))
        dismiss()
    }
}

// MARK: - Menu-bar menu

struct SearchAgentMenu: View {
    @ObservedObject var agent: SearchAgent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(agent.hotKeyPreset == .disabled
               ? "Search Everywhere"
               : "Search Everywhere   \(agent.hotKeyPreset.label)") { agent.togglePanel() }
        Button("Open DiskScope") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        ForEach(agent.volumes) { v in
            Text(volumeLine(v))
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { agent.launchAtLogin },
            set: { agent.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit DiskScope") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func volumeLine(_ v: SearchService.VolumeInfo) -> String {
        let name = v.root == "/" ? "Macintosh HD (/)" : (v.root as NSString).lastPathComponent
        switch v.status {
        case .scanning:            return "\(name) — indexing…"
        case .ready(let entries):  return "\(name) — \(entries.formatted()) items"
        case .failed:              return "\(name) — failed"
        }
    }
}
