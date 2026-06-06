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
    var body: some Scene {
        WindowGroup("DiskScope") { ContentView() }
            .defaultSize(width: 1100, height: 760)
    }
}
