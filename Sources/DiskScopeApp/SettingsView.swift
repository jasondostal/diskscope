import SwiftUI
import DiskScopeCore

/// The Settings window (⌘,). Theme + treemap appearance.
struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 420, height: 280)
    }

    private var appearance: some View {
        Form {
            Picker("Theme", selection: $theme.selectedID) {
                ForEach(Theme.presets) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)

            // Swatch preview of the selected theme.
            HStack(spacing: 4) {
                ForEach(FilePalette.previewCategories, id: \.self) { cat in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.current.palette.color(cat))
                        .frame(height: 16)
                }
            }
            .padding(.vertical, 2)

            Slider(value: $settings.minTileSize, in: 1...8, step: 1) {
                Text("Detail")
            } minimumValueLabel: {
                Text("Fine").font(.caption2)
            } maximumValueLabel: {
                Text("Chunky").font(.caption2)
            }
            Text("Smallest cell the treemap draws (\(Int(settings.minTileSize)) px). Lower shows more tiny files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
