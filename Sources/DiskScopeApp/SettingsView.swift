import SwiftUI
import DiskScopeCore

/// The Settings window (⌘,). Theme + treemap appearance, with live OKLCH custom-theme sliders.
struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var agent = SearchAgent.shared
    @State private var editingCat: FilePalette.Category = .image

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            search.tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .frame(width: 460, height: theme.isCustom ? 700 : 400)
    }

    private var search: some View {
        Form {
            Picker("Global hotkey", selection: $agent.hotKeyPreset) {
                ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Text("Opens the search-everywhere panel from any app. Pick a combo nothing else owns (input-source switchers and certain memory daemons are notorious squatters).")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            Toggle("Launch at login", isOn: Binding(
                get: { agent.launchAtLogin },
                set: { agent.setLaunchAtLogin($0) }))
            Text("Keeps the index warm and the hotkey live from boot — the menu-bar agent starts quietly, no window.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearance: some View {
        ScrollView {
            Form {
                Picker("Theme", selection: $theme.selectedID) {
                    ForEach(Theme.presets) { Text($0.name).tag($0.id) }
                    Text("Custom").tag(Theme.customID)
                }
                .pickerStyle(.menu)

                // Live swatch preview of the selected theme.
                HStack(spacing: 4) {
                    ForEach(FilePalette.previewCategories, id: \.self) { cat in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.current.palette.color(cat))
                            .frame(height: 18)
                    }
                }
                .padding(.vertical, 2)

                if theme.isCustom {
                    customControls
                } else {
                    HStack {
                        Text("Pick **Custom** to tune colors live, or").foregroundStyle(.secondary)
                        Button("Customize \(currentName)…") { theme.customize(from: theme.selectedID) }
                    }
                    .font(.caption)
                }

                Divider().padding(.vertical, 2)

                Slider(value: $settings.minTileSize, in: 1...8, step: 1) {
                    Text("Detail")
                } minimumValueLabel: {
                    Text("Fine").font(.caption2)
                } maximumValueLabel: {
                    Text("Chunky").font(.caption2)
                }
                Text("Smallest cell the treemap draws (\(Int(settings.minTileSize)) px). Lower shows more tiny files.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                Toggle("Fade old files by age", isOn: $theme.recency.enabled)
                if theme.recency.enabled {
                    labeledSlider("Strength", $theme.recency.strength, 0...1, fmt: "%.2f")
                    labeledSlider("Stale after", $theme.recency.horizonDays, 30...1095, fmt: "%.0f d")
                }
                Text("A layer over any theme: files untouched for a while drain toward grey (recent = vivid), so big stale files to clean up pop out. Doesn't change your theme.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                Toggle("Fade by depth", isOn: $theme.depth.enabled)
                if theme.depth.enabled {
                    labeledSlider("Strength", $theme.depth.strength, 0...1, fmt: "%.2f")
                }
                Text("Another layer: deeper-nested files mute toward grey so top-level folders read boldest. Makes the tree structure visible in the map.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private var currentName: String { Theme.presets.first { $0.id == theme.selectedID }?.name ?? "Theme" }

    // MARK: - Custom-theme live controls

    @ViewBuilder private var customControls: some View {
        Section("Global") {
            labeledSlider("Saturation", $theme.custom.chroma, 0...2, fmt: "%.2f×")
            labeledSlider("Lightness", $theme.custom.lightness, -0.12...0.12, fmt: "%+.2f")
            labeledSlider("Cushion ambient", $theme.custom.ambient, 0.3...0.8, fmt: "%.2f")
        }
        Section("Background") {
            labeledSlider("Brightness", $theme.custom.bgL, 0...0.18, fmt: "%.3f")
            labeledSlider("Tint", $theme.custom.bgChroma, 0...0.05, fmt: "%.3f")
            labeledSlider("Hue", $theme.custom.bgHue, 0...360, fmt: "%.0f°")
        }
        Section("Per-category") {
            // Swatch grid — tap one to fine-tune its OKLCH; ring marks the one being edited.
            let cats = FilePalette.Category.allCases
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(cats, id: \.self) { cat in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.current.palette.color(cat))
                        .frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white, lineWidth: editingCat == cat ? 2 : 0))
                        .overlay(theme.custom.overrides[cat] != nil
                                 ? Image(systemName: "pencil").font(.system(size: 7)).foregroundStyle(.white) : nil,
                                 alignment: .topTrailing)
                        .onTapGesture { editingCat = cat }
                        .help(cat.rawValue)
                }
            }
            .padding(.vertical, 2)

            HStack {
                Text(editingCat.rawValue.capitalized).font(.callout.bold())
                Spacer()
                if theme.custom.overrides[editingCat] != nil {
                    Button("Reset") { theme.custom.overrides[editingCat] = nil }.font(.caption)
                }
            }
            labeledSlider("L", catBinding(\.L), 0...1, fmt: "%.2f")
            labeledSlider("C", catBinding(\.C), 0...0.37, fmt: "%.3f")
            labeledSlider("H", catBinding(\.H), 0...360, fmt: "%.0f°")
        }
    }

    /// Effective OKLCH for the category being edited (explicit override, else global-derived).
    private func effectiveOKLCH(_ cat: FilePalette.Category) -> FilePalette.OKLCH {
        theme.custom.overrides[cat] ?? theme.custom.palette.oklch(cat)
    }

    /// A binding to one OKLCH channel of the edited category. Writing promotes it to an
    /// explicit override (seeded from the current effective color so nothing jumps).
    private func catBinding(_ key: WritableKeyPath<FilePalette.OKLCH, Double>) -> Binding<Double> {
        Binding(
            get: { effectiveOKLCH(editingCat)[keyPath: key] },
            set: { newValue in
                var c = effectiveOKLCH(editingCat)
                c[keyPath: key] = newValue
                theme.custom.overrides[editingCat] = c
            })
    }

    private func labeledSlider(_ label: String, _ value: Binding<Double>,
                               _ range: ClosedRange<Double>, fmt: String) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
