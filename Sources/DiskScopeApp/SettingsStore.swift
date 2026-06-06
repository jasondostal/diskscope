import Foundation

/// Persisted user preferences (non-theme). Theme selection lives in ThemeManager.
final class SettingsStore: ObservableObject {
    /// Minimum on-screen cell size (px) before the treemap stops subdividing — lower =
    /// more tiny detail, higher = chunkier/faster.
    @Published var minTileSize: Double {
        didSet { UserDefaults.standard.set(minTileSize, forKey: Keys.minTileSize) }
    }

    private enum Keys {
        static let minTileSize = "diskscope.minTileSize"
    }

    init() {
        let v = UserDefaults.standard.double(forKey: Keys.minTileSize)
        minTileSize = (v >= 1 && v <= 12) ? v : 2
    }
}
