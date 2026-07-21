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
                    case .files:
                        FilesSettingsTab()
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
        .init(title: "Dashboard layout", tab: .appearance, keywords: ["dashboard", "layout", "categories", "grid", "list", "groups", "tools", "arrange"]),
        .init(title: "Reset order", tab: .appearance, keywords: ["reset", "order", "arrange", "rearrange", "default", "dashboard", "sections", "tools", "pin"]),
        .init(title: "Accent color", tab: .appearance, keywords: ["hue", "tint", "color", "accent", "swatch"]),
        .init(title: "Tool colors", tab: .appearance, keywords: ["tool", "colors", "accent", "multicolor", "single", "monochrome", "style"]),
        .init(title: "Glass effect", tab: .appearance, keywords: ["glass", "blur", "frost", "clear", "solid", "material", "translucent"]),
        .init(title: "Tint", tab: .appearance, keywords: ["tint", "wash", "accent", "vivid", "subtle"]),
        .init(title: "Content surface", tab: .appearance, keywords: ["surface", "cards", "unified", "shape"]),
        .init(title: "Tool preview panes", tab: .appearance, keywords: ["preview", "pane", "background", "thumbnail", "merge"]),
        .init(title: "After exporting", tab: .files, keywords: ["export", "save", "reveal", "finder", "open", "after"]),
        .init(title: "Save location", tab: .files, keywords: ["save", "location", "folder", "beside", "original", "destination", "dialog"]),
        .init(title: "Filenames", tab: .files, keywords: ["filename", "name", "suffix", "output"]),
        .init(title: "Reopen last tool", tab: .files, keywords: ["launch", "startup", "reopen", "last", "tool", "dashboard"]),
        .init(title: "Redacted page sharpness", tab: .advanced, keywords: ["redact", "sharpness", "resolution", "quality", "pixels"]),
        .init(title: "Default compression quality", tab: .advanced, keywords: ["compress", "quality", "default", "size"]),
        .init(title: "Strip metadata on export", tab: .advanced, keywords: ["metadata", "strip", "privacy", "author", "title", "dates"]),
        .init(title: "Activity logging level", tab: .advanced, keywords: ["log", "logging", "level", "activity", "debug", "warnings", "errors"]),
        .init(title: "Reset all settings", tab: .advanced, keywords: ["reset", "defaults", "restore", "clear", "all"]),
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

// MARK: - Files tab

/// Output and launch behavior shared by every tool: where files go, what happens after they're
/// saved, how they're named, and whether the last tool reopens on launch.
struct FilesSettingsTab: View {
    @AppStorage(SettingsKeys.saveLocation)
    private var saveLocationRaw: String = SaveLocation.defaultLocation.rawValue
    @AppStorage(SettingsKeys.afterExportAction)
    private var afterExportRaw: String = AfterExportAction.defaultAction.rawValue
    @AppStorage(SettingsKeys.appendFilenameSuffix)
    private var appendFilenameSuffix: Bool = true
    @AppStorage(SettingsKeys.reopenLastTool)
    private var reopenLastTool: Bool = false

    private var saveLocation: SaveLocation { SaveLocation(rawValue: saveLocationRaw) ?? .askEachTime }
    private var afterExport: AfterExportAction { AfterExportAction(rawValue: afterExportRaw) ?? .revealInFinder }

    var body: some View {
        Form {
            Section {
                Picker("Save location", selection: $saveLocationRaw) {
                    ForEach(SaveLocation.allCases) { location in
                        Text(location.displayName).tag(location.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Save location")
            } footer: {
                Text(saveLocation.detail)
            }

            Section {
                Picker("After exporting", selection: $afterExportRaw) {
                    ForEach(AfterExportAction.allCases) { action in
                        Text(action.displayName).tag(action.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("After exporting")
            } footer: {
                Text(afterExport.detail)
            }

            Section {
                Toggle("Add a suffix to output names", isOn: $appendFilenameSuffix)
            } header: {
                Text("Filenames")
            } footer: {
                Text(appendFilenameSuffix
                     ? "Output is named like Report-compressed.pdf, keeping the original file intact."
                     : "Output keeps the source name (Report.pdf). With “Save beside original”, a clash is numbered rather than overwriting.")
            }

            Section {
                Toggle("Reopen the last tool on launch", isOn: $reopenLastTool)
            } header: {
                Text("On launch")
            } footer: {
                Text(reopenLastTool
                     ? "The app reopens whichever tool you used last instead of the dashboard."
                     : "The app always opens to the dashboard.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Appearance tab

struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.accentStyleKey) private var accentStyleRaw: String = AccentStyle.multicolor.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(SettingsKeys.mergePreviewBackground) private var mergePreviewBackgroundRaw: String = MergePreviewBackgroundStyle.matchMain.rawValue
    @AppStorage(SettingsKeys.dashboardLayout) private var dashboardLayoutRaw: String = DashboardLayout.categories.rawValue
    @AppStorage(SettingsKeys.dashboardCategoryOrder) private var dashboardCategoryOrderRaw: String = ""
    @AppStorage(SettingsKeys.dashboardToolOrder) private var dashboardToolOrderRaw: String = ""

    private var dashboardLayout: DashboardLayout { DashboardLayout(rawValue: dashboardLayoutRaw) ?? .categories }

    /// Whether the user has rearranged the dashboard away from its default section/tool order — gates
    /// the Reset order button. Pins are tracked separately (``SettingsKeys/dashboardPinnedTools``) and
    /// deliberately don't count here, so Reset order never removes a pin.
    private var hasCustomDashboardOrder: Bool {
        !ToolCategoryOrder.isDefault(ToolCategoryOrder.resolve(dashboardCategoryOrderRaw))
            || !ToolOrder.isDefault(dashboardToolOrderRaw)
    }
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? LiquidGlass.defaultHue }
    private var accentStyle: AccentStyle { AccentStyle(rawValue: accentStyleRaw) ?? .multicolor }
    private var selectedSurfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var mergeStyle: MergePreviewBackgroundStyle { MergePreviewBackgroundStyle(rawValue: mergePreviewBackgroundRaw) ?? .matchMain }

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

            Section {
                Picker("Dashboard layout", selection: $dashboardLayoutRaw) {
                    ForEach(DashboardLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Dashboard layout")
            } footer: {
                Text(dashboardLayout.detail)
            }

            Section {
                Button("Reset order") { resetDashboardOrder() }
                    .disabled(!hasCustomDashboardOrder)
            } header: {
                Text("Dashboard order")
            } footer: {
                Text(hasCustomDashboardOrder
                     ? "Restores the default order of the dashboard sections and the tools within them. Pinned tools aren’t affected."
                     : "Drag a section header or a tile on the dashboard to rearrange it. Reset order restores the default arrangement; pinned tools aren’t affected.")
            }

            Section("Accent color") {
                HStack(spacing: 5) {
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
                Picker("Tool colors", selection: $accentStyleRaw) {
                    ForEach(AccentStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // A live strip of representative tool icons in their resolved accent, so the effect of
                // the style (and, under Single, the accent hue above) is visible right here.
                AccentStylePreviewStrip(style: accentStyle, hue: selectedHue)
            } header: {
                Text("Tool colors")
            } footer: {
                Text(accentStyle.detail)
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
                    // Dim the readout alongside the disabled slider so it doesn't look live while the
                    // tint has no effect (no accent chosen).
                    Text("\(Int(surfaceTint * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedHue == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
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
        // Apply immediately from the overlay so the theme flips without waiting on the root observer.
        .onChange(of: appearanceModeRaw) { _, _ in
            AppAppearance.applyPersisted()
        }
    }

    /// Clear the custom section and within-section tool order, restoring the dashboard's default
    /// arrangement. Pins are intentionally left in place.
    private func resetDashboardOrder() {
        dashboardCategoryOrderRaw = ""
        dashboardToolOrderRaw = ""
    }
}

/// A live row of representative tool icons rendered in their resolved accent, shown under the
/// "Tool colors" picker so Multicolor vs Single (and, under Single, the accent hue) is visible at a
/// glance rather than only described.
private struct AccentStylePreviewStrip: View {
    let style: AccentStyle
    let hue: LiquidGlassHue

    // A spread of tools whose default colors differ most, so the multicolor → single change is obvious.
    private let sample: [Tool] = [.compress, .merge, .split, .watermark, .redact, .protect]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(sample) { tool in
                let accent = style.accent(for: tool, hue: hue)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.5), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(accent)
                    }
                    .frame(width: 34, height: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.15), value: style)
        .animation(.easeOut(duration: 0.15), value: hue)
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
                    // Twelve hues share one row; the longest name ("Graphite") shrinks to stay on a
                    // single line rather than wrapping in its narrow slot.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

// MARK: - Advanced tab

struct AdvancedSettingsTab: View {
    @AppStorage(SettingsKeys.redactRasterLongEdge)
    private var redactLongEdge: Double = 4000
    @AppStorage(SettingsKeys.defaultCompressionQuality)
    private var compressionQuality: Double = 0.72
    @AppStorage(SettingsKeys.stripMetadataOnExport)
    private var stripMetadata: Bool = false
    @AppStorage(ActivityLog.minimumLevelDefaultsKey)
    private var logLevelRaw: String = ActivityLog.defaultMinimumLevel.rawValue

    /// Coarser-to-finer thresholds shown in the logging picker, each paired with the `LogLevel` whose
    /// raw value is persisted. `.debug` logs everything; `.error` keeps only failures.
    private static let logOptions: [(label: String, level: LogLevel)] = [
        ("Everything", .debug),
        ("Info and above", .info),
        ("Warnings and errors", .warning),
        ("Errors only", .error),
    ]

    private var compressionLabel: String {
        switch compressionQuality {
        case ..<0.45: return "Smaller file"
        case ..<0.75: return "Balanced"
        default: return "Higher quality"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Activity logging level", selection: $logLevelRaw) {
                    ForEach(Self.logOptions, id: \.level.rawValue) { option in
                        Text(option.label).tag(option.level.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Activity logging level")
            } footer: {
                Text("How much detail the Activity Log records. Every setting still logs failures; higher thresholds just record fewer routine events.")
            }

            Section {
                HStack(spacing: 12) {
                    // Same 0.2…1 range as the Compress tool's own slider — the two edit one persisted
                    // value, so their bounds must match or a value set in one is misrepresented in the other.
                    Slider(value: $compressionQuality, in: 0.2...1)
                    Text(compressionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
            } header: {
                Text("Default compression quality")
            } footer: {
                Text("The quality the Compress tool starts on. Also remembers wherever you leave its slider.")
            }

            Section {
                HStack(spacing: 12) {
                    // Same range/step as the Redact tool's own slider (and the redact operation's
                    // clamp): the two controls edit one persisted value, so their bounds must match or
                    // a value set in one is silently clamped/misrepresented in the other.
                    Slider(value: $redactLongEdge, in: 2400...7200, step: 200)
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
                Toggle("Strip metadata on export", isOn: $stripMetadata)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Clears the document's author, title, and dates from every saved PDF. Everything already runs on your Mac; this keeps that info out of files you share.")
            }

            Section {
                Button("Reset all settings", role: .destructive) {
                    resetAllSettings()
                }
            } footer: {
                Text("Restores every setting — Files, Appearance, and Advanced — to its default.")
            }

            Section("About") {
                Text("Native macOS tools for everyday PDF tasks — compress, split, merge, watermark, protect, and more. Everything runs on your Mac; no files leave your machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    LabeledContent("Version", value: "\(AppBrand.displayName) \(version)")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The log gate is seeded once at launch; apply changes live so the Activity Log reflects the
        // new threshold without a relaunch.
        .onChange(of: logLevelRaw) { _, newValue in
            ActivityLog.shared.minimumLevel = LogLevel(rawValue: newValue) ?? ActivityLog.defaultMinimumLevel
        }
    }

    private func resetAllSettings() {
        let defaults = UserDefaults.standard
        for key in [
            // Appearance
            LiquidGlass.appearanceModeKey,
            LiquidGlass.hueKey,
            LiquidGlass.accentStyleKey,
            LiquidGlass.levelKey,
            LiquidGlass.surfaceStyleKey,
            LiquidGlass.tintKey,
            ListDensity.defaultsKey,
            SettingsKeys.mergePreviewBackground,
            SettingsKeys.dashboardLayout,
            SettingsKeys.dashboardCategoryOrder,
            SettingsKeys.dashboardToolOrder,
            SettingsKeys.dashboardPinnedTools,
            // Files
            SettingsKeys.saveLocation,
            SettingsKeys.afterExportAction,
            SettingsKeys.appendFilenameSuffix,
            SettingsKeys.reopenLastTool,
            SettingsKeys.lastToolUsed,
            // Advanced
            SettingsKeys.redactRasterLongEdge,
            SettingsKeys.defaultCompressionQuality,
            SettingsKeys.stripMetadataOnExport,
            ActivityLog.minimumLevelDefaultsKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        // Re-seed glassLevel (its absence would trigger the legacy migration path again) and re-apply
        // the now-default (System) theme + logging gate.
        defaults.set(GlassLevel.frosted.rawValue, forKey: LiquidGlass.levelKey)
        ActivityLog.shared.minimumLevel = ActivityLog.defaultMinimumLevel
        AppAppearance.applyPersisted()
    }
}
