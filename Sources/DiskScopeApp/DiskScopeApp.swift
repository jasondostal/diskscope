import SwiftUI
import AppKit

/// App lifecycle for the dual-personality app: a regular windowed app while you're
/// mapping a disk, a menu-bar agent (⌥Space search, live indexes) once the window
/// closes. Quitting is explicit — the status menu or ⌘Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SearchAgent.shared.start()
        // Last real window gone → drop the dock icon, keep the agent. NSPanels (the
        // search panel) and the status-bar window can't become main, so they don't count.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let anyMain = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !anyMain { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// The agent lives past the last window — quit is explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Dock-icon click (or `open -a`) while windowless → become a regular app again and
    /// let SwiftUI restore the main window.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSApp.setActivationPolicy(.regular) }
        return true
    }

    func applicationWillTerminate(_: Notification) {
        SearchAgent.shared.saveAll()
    }
}

@main
struct DiskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var theme = ThemeManager()
    @StateObject private var settings = SettingsStore()
    @ObservedObject private var agent = SearchAgent.shared

    var body: some Scene {
        Window("DiskScope", id: "main") {
            ContentView()
                .environmentObject(theme)
                .environmentObject(settings)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Theme") {
                Picker("Theme", selection: $theme.selectedID) {
                    ForEach(Theme.presets) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
        }

        // The Everything layer: always-visible menu-bar presence for the search agent.
        MenuBarExtra("DiskScope", systemImage: "internaldrive") {
            SearchAgentMenu(agent: agent)
        }

        Settings {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(settings)
        }
    }
}
