import Foundation
import AppKit

/// Full Disk Access detection + the jump to System Settings. Without FDA, a whole-disk
/// scan silently misses protected locations (Mail, Messages, other apps' data, etc.).
enum FullDiskAccess {
    /// Probe by trying to open the TCC database — it exists on every Mac and open() is
    /// gated by TCC, so success means we hold Full Disk Access.
    static func granted() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// Deep-link to System Settings → Privacy & Security → Full Disk Access.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
