import AppKit
import SwiftUI

/// In-window Settings overlay card, styling and structure following SyncCloud `Modules/Settings`.
/// The host (RootView) frames it with the glass material, tint wash, scrim, and drop shadow; this
/// view is just the 620×560 card content: header, cross-tab search, a segmented tab bar, and the
/// selected tab's `Form`.
public struct SettingsView: View {
    @Binding private var selectedTab: SettingsTab
    private let onClose: () -> Void

    @State private var searchQuery = ""

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SettingsSearchEntry] {
        SettingsSearchEntry.filter(SettingsSearchEntry.all, query: searchQuery)
    }

    public init(selection: Binding<SettingsTab>, onClose: @escaping () -> Void) {
        _selectedTab = selection
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                CloseButton(action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .help("Close settings")
                    .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // A segmented picker, not a TabView: a plain TabView outside the native Settings scene
            // hoists its tab bar into the window toolbar. This keeps the tabs inside the card.
            Picker("Settings section", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .disabled(isSearching)

            Divider()

            Group {
                if isSearching {
                    SettingsSearchResults(results: searchResults) { tab in
                        selectedTab = tab
                        searchQuery = ""
                    }
                } else {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsTab()
                    case .appearance:
                        AppearanceSettingsTab()
                    case .advanced:
                        AdvancedSettingsTab()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 560)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search settings", text: $searchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }
}

// MARK: - Search

/// One searchable setting: which tab it lives on, its title, and keywords so "blur" finds
/// "Glass effect" and "lock" finds nothing (there is no password setting) — the System Settings
/// search pattern, scoped to what this app actually exposes.
struct SettingsSearchEntry: Identifiable {
    let id = UUID()
    let title: String
    let tab: SettingsTab
    let keywords: [String]

    static let all: [SettingsSearchEntry] = [
        .init(title: "Theme", tab: .appearance, keywords: ["light", "dark", "system", "appearance", "mode"]),
        .init(title: "Accent color", tab: .appearance, keywords: ["hue", "tint", "color", "accent", "swatch"]),
        .init(title: "Glass effect", tab: .appearance, keywords: ["glass", "blur", "frost", "clear", "solid", "material", "translucent"]),
        .init(title: "Tint", tab: .appearance, keywords: ["tint", "wash", "accent", "vivid", "subtle"]),
        .init(title: "Content surface", tab: .appearance, keywords: ["surface", "cards", "unified", "shape"]),
        .init(title: "List density", tab: .appearance, keywords: ["density", "compact", "comfortable", "rows", "spacing"]),
        .init(title: "Tool preview panes", tab: .general, keywords: ["preview", "pane", "background", "thumbnail", "merge"]),
        .init(title: "Redacted page sharpness", tab: .advanced, keywords: ["redact", "sharpness", "resolution", "quality", "pixels"]),
        .init(title: "Restore appearance defaults", tab: .advanced, keywords: ["reset", "defaults", "restore", "clear"]),
    ]

    static func filter(_ entries: [SettingsSearchEntry], query: String) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return entries.filter { entry in
            entry.title.lowercased().contains(q) || entry.keywords.contains { $0.contains(q) }
        }
    }
}

private struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let onSelect: (SettingsTab) -> Void

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No matching settings")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { entry in
                Button {
                    onSelect(entry.tab)
                } label: {
                    HStack {
                        Text(entry.title)
                        Spacer()
                        Text(entry.tab.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Appearance tab

struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? LiquidGlass.defaultHue }
    private var selectedSurfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Theme")
            } footer: {
                Text(appearanceMode.detail)
            }

            Section("Accent color") {
                HStack(spacing: 8) {
                    ForEach(LiquidGlassHue.allCases) { hue in
                        HueOptionView(
                            hue: hue,
                            isSelected: selectedHue == hue,
                            action: { selectedHueRaw = hue.rawValue }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                Picker("Glass effect", selection: $glassLevelRaw) {
                    ForEach(GlassLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Glass effect")
            } footer: {
                Text(glassLevel.detail)
            }

            Section {
                HStack(spacing: 12) {
                    Slider(value: $surfaceTint, in: 0.0...1.0) {
                        Text("Tint")
                    } minimumValueLabel: {
                        Text("Subtle").font(.caption).foregroundStyle(.secondary).fixedSize()
                    } maximumValueLabel: {
                        Text("Vivid").font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .disabled(selectedHue == .none)
                    Text("\(Int(surfaceTint * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } header: {
                Text("Tint")
            } footer: {
                Text(selectedHue == .none
                     ? "Choose an accent color above to tint the window and its surfaces."
                     : "Washes the window and its surfaces with the accent color chosen above.")
            }

            Section {
                Picker("Content surface", selection: $surfaceStyleRaw) {
                    ForEach(SurfaceStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Content surface")
            } footer: {
                Text(selectedSurfaceStyle.detail)
            }

            Section {
                Picker("List density", selection: $listDensityRaw) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.displayName).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("List density")
            } footer: {
                Text("Comfortable keeps the standard spacing. Compact tightens rows in the Merge and Reorder lists so more fits on screen.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Apply immediately from the overlay so the theme flips without waiting on the root observer.
        .onChange(of: appearanceModeRaw) { _, _ in
            AppAppearance.applyPersisted()
        }
    }
}

/// A selectable hue option for the liquid glass accent color (SyncCloud `HueOptionView`).
private struct HueOptionView: View {
    let hue: LiquidGlassHue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    swatch
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2)
                        )
                        .shadow(color: swatchShadowColor, radius: isSelected ? 5 : 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            // Pairs the checkmark with the swatch's own fill (white is ~2.1:1 on
                            // amber). "None" has no fill of its own, so it tracks the appearance.
                            .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The colored disc for a hue, or a neutral slashed disc for "None".
    @ViewBuilder
    private var swatch: some View {
        if hue == .none {
            ZStack {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 1.5, height: 44)
                    .rotationEffect(.degrees(45))
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        } else {
            Circle().fill(hue.accentColor)
        }
    }

    private var swatchShadowColor: Color {
        hue == .none ? Color.black.opacity(0.2) : hue.accentColor.opacity(0.4)
    }
}

// MARK: - General tab

struct GeneralSettingsTab: View {
    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergePreviewBackgroundRaw: String = MergePreviewBackgroundStyle.white.rawValue

    private var mergeStyle: MergePreviewBackgroundStyle {
        MergePreviewBackgroundStyle(rawValue: mergePreviewBackgroundRaw) ?? .white
    }

    var body: some View {
        Form {
            Section("About") {
                Text("Native macOS tools for everyday PDF tasks — compress, split, merge, watermark, protect, and more. Everything runs on your Mac; no files leave your machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Preview pane", selection: $mergePreviewBackgroundRaw) {
                    ForEach(MergePreviewBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Tool preview panes")
            } footer: {
                Text(mergeStyle.detail)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Advanced tab

struct AdvancedSettingsTab: View {
    @AppStorage(SettingsKeys.redactRasterLongEdge)
    private var redactLongEdge: Double = 4000

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Slider(value: $redactLongEdge, in: 1500...6000, step: 250)
                    Text("\(Int(redactLongEdge)) px")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            } header: {
                Text("Redacted page sharpness")
            } footer: {
                Text("Pixels on the longest edge when a redacted page is rasterized. Higher is sharper but larger and slower.")
            }

            Section {
                Button("Restore appearance defaults", role: .destructive) {
                    restoreAppearanceDefaults()
                }
            } footer: {
                Text("Resets theme, accent, glass, tint, content surface, and list density to their defaults.")
            }

            Section {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    LabeledContent("Version", value: "\(AppBrand.displayName) \(version)")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func restoreAppearanceDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            LiquidGlass.appearanceModeKey,
            LiquidGlass.hueKey,
            LiquidGlass.levelKey,
            LiquidGlass.surfaceStyleKey,
            LiquidGlass.tintKey,
            ListDensity.defaultsKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        // Re-seed glassLevel (its absence would trigger the legacy migration path again) and re-apply
        // the now-default (System) theme.
        defaults.set(GlassLevel.frosted.rawValue, forKey: LiquidGlass.levelKey)
        AppAppearance.applyPersisted()
    }
}
