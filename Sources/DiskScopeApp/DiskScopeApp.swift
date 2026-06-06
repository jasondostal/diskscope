import SwiftUI
import AppKit

/// Bring a SwiftPM-built (bundle-less) GUI to the foreground with a real window + dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

@main
struct DiskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var theme = ThemeManager()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup("DiskScope") {
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

        Settings {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(settings)
        }
    }
}
