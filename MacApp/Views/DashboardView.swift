import SwiftUI
import PdfToolkit

struct DashboardView: View {
    @EnvironmentObject private var settings: SettingsPresenter
    @EnvironmentObject private var help: HelpPresenter
    @Environment(\.openWindow) private var openWindow

    @AppStorage(LiquidGlass.surfaceStyleKey)
    private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(SettingsKeys.dashboardLayout)
    private var dashboardLayoutRaw: String = DashboardLayout.categories.rawValue

    @State private var searchQuery = ""

    private var floatingTiles: Bool {
        (SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified) == .cards
    }

    private var dashboardLayout: DashboardLayout {
        DashboardLayout(rawValue: dashboardLayoutRaw) ?? .categories
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20),
    ]

    /// Tools matching the current query, fuzzy-ranked by the very matcher the ⌘K palette uses
    /// (`rankedToolMatches`), flattened across categories with non-matches dropped. Only read while
    /// `isSearching`.
    private var matchedTools: [Tool] {
        rankedToolMatches(query: searchQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                content
            }
            .padding(32)
        }
        .background(DashboardBackground())
        .navigationTitle(AppBrand.displayName)
        .navigationDestination(for: Tool.self) { tool in
            // Re-inject the presenters so ToolDetailView's toolbar gear (Settings) and "?" (Help) can
            // open their overlays — environment objects don't always survive the navigation boundary.
            ToolDetailView(tool: tool)
                .environmentObject(settings)
                .environmentObject(help)
        }
        .toolbar {
            // macOS 26's grouped toolbar no longer trails `.primaryAction` on its own, so a leading
            // flexible spacer keeps the utility pill on the right (SyncCloud parity).
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "activity-log")
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Open Activity Log")
                .accessibilityLabel("Activity Log")
                Button {
                    settings.open()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Open Settings")
                .accessibilityLabel("Settings")
                Button {
                    help.openHome()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("\(AppBrand.displayName) Help")
                .accessibilityLabel("Help")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tools")
                    .font(.largeTitle.weight(.semibold))
                Text("Pick a tool to work on your PDFs.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            searchField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A standard macOS search field: glyph + plain field + a clear button, on the shared
    /// `searchFieldSurface`. Kept to a sensible width so it reads as a search field, not a banner.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search tools", text: $searchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search tools")
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
        .frame(maxWidth: 360, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            // A live query flattens every layout to matches only. Categories/Grid keep their tiles;
            // List keeps its rows.
            if matchedTools.isEmpty {
                noMatches
            } else if dashboardLayout == .list {
                toolList(matchedTools)
            } else {
                toolGrid(matchedTools)
            }
        } else {
            switch dashboardLayout {
            case .categories: categoriesContent
            case .grid: toolGrid(Tool.allCases)
            case .list: toolList(Tool.allCases)
            }
        }
    }

    private var categoriesContent: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(ToolCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 16) {
                    categoryHeader(category)
                    toolGrid(category.tools)
                }
            }
        }
    }

    /// A section label in the artifact's treatment — small, uppercase, letter-spaced — trailed by a
    /// hairline rule that runs to the edge, in native SF type.
    private func categoryHeader(_ category: ToolCategory) -> some View {
        HStack(spacing: 12) {
            Text(category.displayName.uppercased())
                .font(.subheadline.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(.primary.opacity(0.10))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(.isHeader)
    }

    /// The flat adaptive tile grid — the app's original dashboard body, reused verbatim for Grid mode,
    /// each category section, and tile-mode search results.
    private func toolGrid(_ tools: [Tool]) -> some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(tools) { tool in
                NavigationLink(value: tool) {
                    ToolTileView(tool: tool, floating: floatingTiles)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toolList(_ tools: [Tool]) -> some View {
        VStack(spacing: 8) {
            ForEach(tools) { tool in
                NavigationLink(value: tool) {
                    ToolRowView(tool: tool, floating: floatingTiles)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No tools match “\(trimmedQuery)”")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 56)
    }
}

struct ToolTileView: View {
    let tool: Tool
    /// Cards mode: each tile is an elevated floating card. Unified: tiles read as one flat surface.
    var floating: Bool = true
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var glassTint: Double = 0
    @AppStorage(LiquidGlass.accentStyleKey) private var accentStyleRaw: String = AccentStyle.multicolor.rawValue
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }
    /// The tile's effective accent under the chosen accent-style preset (the dashboard sits outside the
    /// tool screen's `\.toolAccent`, so it resolves here directly).
    private var accent: Color {
        (AccentStyle(rawValue: accentStyleRaw) ?? .multicolor).accent(for: tool, hue: glassHue)
    }

    // Black shadows are near-invisible on a dark ground, so dark carries a deeper shadow — with a
    // non-zero floor even when idle/unified — to lift the tile. Light keeps the original values.
    private var shadowOpacity: Double {
        if dark { return floating ? (hovered ? 0.66 : 0.50) : (hovered ? 0.44 : 0.30) }
        return floating ? (hovered ? 0.14 : 0.06) : (hovered ? 0.08 : 0.0)
    }
    private var shadowRadius: CGFloat {
        if dark { return floating ? (hovered ? 23 : 17) : (hovered ? 14 : 10) }
        return floating ? (hovered ? 18 : 10) : (hovered ? 10 : 0)
    }
    private var shadowY: CGFloat {
        if dark { return floating ? (hovered ? 9 : 5) : (hovered ? 5 : 3) }
        return floating ? (hovered ? 8 : 4) : (hovered ? 4 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: dark
                                ? [accent.opacity(0.64), accent.opacity(0.27)]
                                : [accent.opacity(0.30), accent.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 92)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(accent.opacity(dark ? 0.60 : 0.22), lineWidth: 1)
                    }
                    // Dark-only inner top highlight so the plate reads as lit glass, not a flat chip.
                    .overlay {
                        if dark {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.36), .clear],
                                                   startPoint: .top, endPoint: .center),
                                    lineWidth: 1
                                )
                        }
                    }
                Image(systemName: tool.symbolName)
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(hovered ? 0.35 : 0), radius: 6)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(tool.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(tool.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Reserve two lines even for a one-line subtitle so every tile in a row shares a
                    // baseline — titles and the hover "Open" affordance line up across the grid.
                    .lineLimit(2, reservesSpace: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Text("Open")
                Image(systemName: "arrow.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .opacity(hovered ? 1 : 0)
            .offset(x: hovered ? 0 : -4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        // Make the whole tile the tap target, not just the icon/text: the glass background isn't part
        // of the enclosing NavigationLink's hit region on its own, so clicks in the empty areas would
        // otherwise miss.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // The accent tint wash, so the Tint slider washes the dashboard tiles the same way it washes
        // the Settings card and tool control cards (contentSurface). Sits behind the tile content and
        // under the glass — apply before clip/glassSurface, exactly like FormCardStyle.
        .contentSurface(hue: glassHue, tint: glassTint)
        // Same glass surface as the window background, so Clear shows the desktop through each tile
        // too (glassEffect(.clear) on macOS 26), Frosted blurs it, Solid stays opaque.
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(glassLevel, cornerRadius: 22)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    hovered ? accent.opacity(0.6)
                            : (dark ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)),
                    lineWidth: hovered ? 1.5 : 1
                )
        }
        // Dark-only specular: a bright top edge fading by the middle, so the tile catches light like
        // real glass. Skipped while hovered (the accent border takes over) and in light mode.
        .overlay {
            if dark && !hovered {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.40), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
            }
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
        .scaleEffect(hovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.18), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.title). \(tool.subtitle)")
    }
}

/// The compact table row for the List layout: a small accent icon plate, the tool's title and
/// one-line subtitle, and a trailing chevron. Reads the same glass/accent settings as `ToolTileView`
/// (directly, since the dashboard sits outside the tool screen's `\.toolAccent`) so the List mode
/// honors Multicolor/Single, the glass level, and the tint wash exactly like the tiles do.
struct ToolRowView: View {
    let tool: Tool
    /// Cards mode lifts each row with a soft shadow; Unified keeps them flat, like a plain table.
    var floating: Bool = true
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var glassTint: Double = 0
    @AppStorage(LiquidGlass.accentStyleKey) private var accentStyleRaw: String = AccentStyle.multicolor.rawValue
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }
    private var accent: Color {
        (AccentStyle(rawValue: accentStyleRaw) ?? .multicolor).accent(for: tool, hue: glassHue)
    }

    private var shadowOpacity: Double {
        if dark { return hovered ? 0.40 : (floating ? 0.28 : 0.16) }
        return hovered ? 0.10 : (floating ? 0.05 : 0.0)
    }

    var body: some View {
        HStack(spacing: 14) {
            iconPlate
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(tool.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(hovered ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Whole row is the hit target (the glass fill isn't part of the NavigationLink's region alone).
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentSurface(hue: glassHue, tint: glassTint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassSurface(glassLevel, cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    hovered ? accent.opacity(0.6)
                            : (dark ? Color.white.opacity(0.16) : Color.primary.opacity(0.07)),
                    lineWidth: hovered ? 1.5 : 1
                )
        }
        .shadow(color: .black.opacity(shadowOpacity),
                radius: hovered ? 10 : (floating ? 6 : 0),
                y: hovered ? 4 : (floating ? 2 : 0))
        .animation(.easeOut(duration: 0.16), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.title). \(tool.subtitle)")
    }

    private var iconPlate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: dark
                            ? [accent.opacity(0.64), accent.opacity(0.27)]
                            : [accent.opacity(0.30), accent.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent.opacity(dark ? 0.60 : 0.22), lineWidth: 1)
                }
            Image(systemName: tool.symbolName)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
        }
    }
}
