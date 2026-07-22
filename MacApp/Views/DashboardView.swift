import SwiftUI
import UniformTypeIdentifiers
import PdfToolkit

struct DashboardView: View {
    @EnvironmentObject private var settings: SettingsPresenter
    @EnvironmentObject private var help: HelpPresenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(LiquidGlass.surfaceStyleKey)
    private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(SettingsKeys.dashboardLayout)
    private var dashboardLayoutRaw: String = DashboardLayout.categories.rawValue
    @AppStorage(SettingsKeys.dashboardCategoryOrder)
    private var categoryOrderRaw: String = ""
    @AppStorage(SettingsKeys.dashboardToolOrder)
    private var toolOrderRaw: String = ""
    @AppStorage(SettingsKeys.dashboardPinnedTools)
    private var pinnedRaw: String = ""

    @State private var searchQuery = ""

    // The in-flight drag. Exactly one of a tool drag (within a section/Pinned) or a category drag (a
    // whole section) is live at a time; the two never mix, which is how the tool and category drop
    // targets — all registered on the same `.text` payload — tell each other's drags apart (a tool
    // drop ignores the event when `draggingToolGroup` is nil, and a header ignores it when
    // `draggingCategory` is nil).
    @State private var draggingTool: Tool?
    @State private var draggingToolGroup: ToolDragGroup?
    @State private var draggingCategory: ToolCategory?

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

    /// The Categories-view section order: the user's saved arrangement, always resolved to the full,
    /// deduplicated set of categories (see ``ToolCategoryOrder``).
    private var orderedCategories: [ToolCategory] {
        ToolCategoryOrder.resolve(categoryOrderRaw)
    }

    /// The tools the user has pinned to the top, in pin order (see ``PinnedTools``).
    private var pinnedTools: [Tool] {
        PinnedTools.resolve(pinnedRaw)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20),
    ]

    /// The spring the reorder/pinning reflow settles with — a light overshoot so tiles and sections
    /// snap into place rather than sliding linearly. Shared by the drag drops and the accessibility
    /// moves so every rearrangement lands the same way. (Reset dashboard order itself now lives in Settings.)
    /// Collapses to an instant, motionless change when the user has asked to reduce motion — the
    /// reflow still happens, just without the spring travel/overshoot.
    private var reorderSpring: Animation {
        reduceMotion ? .linear(duration: 0) : .spring(response: 0.3, dampingFraction: 0.72)
    }

    /// Tools matching the current query, fuzzy-ranked by the very matcher the ⌘K palette uses
    /// (`rankedToolMatches`), flattened across categories with non-matches dropped. Only read while
    /// `isSearching`.
    private var matchedTools: [Tool] {
        rankedToolMatches(query: searchQuery)
    }

    /// `tools` with the pinned ones lifted to the front in pin order — how Grid and List honor pins
    /// without a separate section. A single instance each (unlike Categories, where a pin is a
    /// shortcut and the tool also keeps its home-section tile).
    private func hoistingPins(_ tools: [Tool]) -> [Tool] {
        let pins = pinnedTools
        guard !pins.isEmpty else { return tools }
        return pins + tools.filter { !pins.contains($0) }
    }

    // MARK: - Reordering & pinning

    private func moveCategory(_ category: ToolCategory, _ direction: ToolCategoryOrder.MoveDirection) {
        let next = ToolCategoryOrder.moving(category, direction, in: orderedCategories)
        withAnimation(reorderSpring) {
            categoryOrderRaw = ToolCategoryOrder.serialize(next)
        }
    }

    /// Persist a group's freshly-reordered tool list. Pinned writes the pin order; a category writes
    /// its within-section order.
    private func commitToolOrder(_ tools: [Tool], in group: ToolDragGroup) {
        switch group {
        case .pinned:
            pinnedRaw = PinnedTools.serialize(tools)
        case .category(let category):
            toolOrderRaw = ToolOrder.replacing(category, with: tools, in: toolOrderRaw)
        }
    }

    /// Move a tool one slot within its group — the keyboard/VoiceOver equivalent of a drag, exposed as
    /// an accessibility action since drag-and-drop is invisible to assistive tech.
    private func moveTool(_ tool: Tool, _ direction: ToolCategoryOrder.MoveDirection, in group: ToolDragGroup) {
        withAnimation(reorderSpring) {
            switch group {
            case .pinned:
                pinnedRaw = PinnedTools.moving(tool, direction, in: pinnedRaw)
            case .category:
                toolOrderRaw = ToolOrder.moving(tool, direction, in: toolOrderRaw)
            }
        }
    }

    private func togglePin(_ tool: Tool) {
        withAnimation(reorderSpring) {
            pinnedRaw = PinnedTools.toggling(tool, in: pinnedRaw)
        }
    }

    /// End the current drag session — clears whichever drag was live so a dropped (or cancelled) tile
    /// stops reading as "lifted".
    private func clearDragging() {
        draggingTool = nil
        draggingToolGroup = nil
        draggingCategory = nil
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
            HStack(spacing: 12) {
                searchField
                Spacer(minLength: 0)
            }
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
            // List keeps its rows. Pinning and reordering are suppressed here — search is a transient,
            // ranked view, not an arrangement you edit.
            if matchedTools.isEmpty {
                noMatches
            } else if dashboardLayout == .list {
                toolList(matchedTools, pinnable: false)
            } else {
                toolGrid(matchedTools, pinnable: false)
            }
        } else {
            switch dashboardLayout {
            case .categories: categoriesContent
            case .grid: toolGrid(hoistingPins(Tool.allCases), pinnable: true)
            case .list: toolList(hoistingPins(Tool.allCases), pinnable: true)
            }
        }
    }

    private var categoriesContent: some View {
        let categories = orderedCategories
        let pinned = pinnedTools
        return VStack(alignment: .leading, spacing: 32) {
            if !pinned.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    pinnedHeader
                    reorderableGrid(pinned, group: .pinned)
                }
                .transition(.opacity)
            }
            ForEach(Array(categories.enumerated()), id: \.element) { _, category in
                CategorySectionView(
                    category: category,
                    isDragging: draggingCategory == category,
                    makeDragProvider: {
                        draggingCategory = category
                        return NSItemProvider(object: category.rawValue as NSString)
                    },
                    dropDelegate: CategoryReorderDropDelegate(
                        target: category,
                        order: categories,
                        dragging: draggingCategory,
                        move: { next in
                            withAnimation(reorderSpring) {
                                categoryOrderRaw = ToolCategoryOrder.serialize(next)
                            }
                        },
                        end: clearDragging
                    ),
                    onMove: { moveCategory(category, $0) }
                ) {
                    reorderableGrid(ToolOrder.resolve(toolOrderRaw, for: category), group: .category(category))
                }
            }
        }
        // Catches drops that land in the gaps between tiles/sections so a cancelled drag still ends
        // cleanly; the per-tile and per-header delegates handle drops on an actual target.
        .onDrop(of: [.text], delegate: DragSessionEndDelegate(end: clearDragging))
    }

    /// The Pinned section's header: a pin glyph + label + hairline. Deliberately *not* a drag handle —
    /// Pinned is fixed at the top of the Categories view.
    private var pinnedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pinned".uppercased())
                .font(.subheadline.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(.primary.opacity(0.10))
                .frame(height: 1)
        }
    }

    /// A grid of draggable, reorderable tiles for one group (a category or Pinned). The whole tile is
    /// the drag handle; a quick click still opens the tool (the system's drag threshold separates the
    /// two), and the hover pin button toggles the pin.
    private func reorderableGrid(_ tools: [Tool], group: ToolDragGroup) -> some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(tools) { tool in
                let pinned = PinnedTools.contains(tool, in: pinnedRaw)
                let dragging = draggingTool == tool && draggingToolGroup == group
                NavigationLink(value: tool) {
                    ToolTileView(tool: tool, floating: floatingTiles, isPinned: pinned) {
                        togglePin(tool)
                    }
                }
                .buttonStyle(.plain)
                // Lift the dragged tile out of the grid — fade and shrink it so its slot reads as an
                // empty gap the OS drag image is being carried out of, rather than a hard-dimmed ghost.
                .opacity(dragging ? 0.28 : 1)
                .scaleEffect(dragging ? 0.92 : 1)
                .zIndex(dragging ? 1 : 0)
                .animation(reorderSpring, value: dragging)
                .onDrag {
                    draggingTool = tool
                    draggingToolGroup = group
                    return NSItemProvider(object: tool.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: ToolReorderDropDelegate(
                    target: tool,
                    group: group,
                    orderedTools: tools,
                    draggingTool: draggingTool,
                    draggingGroup: draggingToolGroup,
                    move: { next in
                        withAnimation(reorderSpring) {
                            commitToolOrder(next, in: group)
                        }
                    },
                    end: clearDragging
                ))
                .accessibilityAction(named: pinned ? "Unpin from top" : "Pin to top") { togglePin(tool) }
                .accessibilityAction(named: "Move up") { moveTool(tool, .up, in: group) }
                .accessibilityAction(named: "Move down") { moveTool(tool, .down, in: group) }
            }
        }
    }

    /// The flat adaptive tile grid — Grid mode and tile-mode search results. `pinnable` shows the pin
    /// button and marks pinned tiles; search passes `false`.
    @ViewBuilder
    private func toolGrid(_ tools: [Tool], pinnable: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(tools) { tool in
                let pinned = pinnable && PinnedTools.contains(tool, in: pinnedRaw)
                let link = NavigationLink(value: tool) {
                    ToolTileView(tool: tool, floating: floatingTiles, isPinned: pinned,
                                 onTogglePin: pinnable ? { togglePin(tool) } : nil)
                }
                .buttonStyle(.plain)
                if pinnable {
                    link.accessibilityAction(named: pinned ? "Unpin from top" : "Pin to top") { togglePin(tool) }
                } else {
                    link
                }
            }
        }
    }

    @ViewBuilder
    private func toolList(_ tools: [Tool], pinnable: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(tools) { tool in
                let pinned = pinnable && PinnedTools.contains(tool, in: pinnedRaw)
                let link = NavigationLink(value: tool) {
                    ToolRowView(tool: tool, floating: floatingTiles, isPinned: pinned,
                                onTogglePin: pinnable ? { togglePin(tool) } : nil)
                }
                .buttonStyle(.plain)
                if pinnable {
                    link.accessibilityAction(named: pinned ? "Unpin from top" : "Pin to top") { togglePin(tool) }
                } else {
                    link
                }
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

/// Which reorder scope a tile belongs to. Tool drags never cross groups (you can't drag a tile out of
/// its section, and pinning is the hover button's job), so the group both scopes a drag and lets the
/// tool and category drop targets — sharing one `.text` payload — ignore each other's drags.
private enum ToolDragGroup: Equatable {
    case pinned
    case category(ToolCategory)
}

/// One category section in the Categories view: a header that doubles as the section's drag handle,
/// above the section's reorderable tile grid. Owns its own hover state so the grip affordance stays
/// hidden until the pointer is over the header — keeping the dashboard clean when you're not
/// rearranging. The whole header (not just the grip) is the draggable target, so losing the pointer
/// off the small glyph never strands the drag.
private struct CategorySectionView<Grid: View>: View {
    let category: ToolCategory
    let isDragging: Bool
    let makeDragProvider: () -> NSItemProvider
    let dropDelegate: CategoryReorderDropDelegate
    let onMove: (ToolCategoryOrder.MoveDirection) -> Void
    @ViewBuilder let grid: () -> Grid

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            grid()
        }
        .opacity(isDragging ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: isDragging)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // A drag-handle hint that fades in on hover. It's only a cue — the entire header row is the
            // drag target, so the reveal-on-hover can't repeat the old arrows' "reach it and it's gone".
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .accessibilityHidden(true)
            Text(category.displayName.uppercased())
                .font(.subheadline.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(.primary.opacity(0.10))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDrag(makeDragProvider)
        .onDrop(of: [.text], delegate: dropDelegate)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.displayName) section")
        .accessibilityAction(named: "Move up") { onMove(.up) }
        .accessibilityAction(named: "Move down") { onMove(.down) }
    }
}

// MARK: - Drag & drop delegates

/// Live-reorders a group's tiles as the pointer crosses each one during a drag. It reads the drag from
/// `@State` rather than the drop payload, so it can ignore a *category* drag (when `draggingGroup` is
/// nil) even though both drags share the `.text` type.
private struct ToolReorderDropDelegate: DropDelegate {
    let target: Tool
    let group: ToolDragGroup
    let orderedTools: [Tool]
    let draggingTool: Tool?
    let draggingGroup: ToolDragGroup?
    let move: ([Tool]) -> Void
    let end: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingTool != nil && draggingGroup == group }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingTool, draggingGroup == group, dragged != target,
              let from = orderedTools.firstIndex(of: dragged),
              let to = orderedTools.firstIndex(of: target) else { return }
        var next = orderedTools
        next.remove(at: from)
        guard let anchor = next.firstIndex(of: target) else { return }
        // Insert after the target when sweeping forward, before it when sweeping back — the classic
        // reorder feel as the pointer crosses tiles.
        next.insert(dragged, at: from < to ? anchor + 1 : anchor)
        move(next)
    }

    func performDrop(info: DropInfo) -> Bool { end(); return true }
}

/// Live-reorders the category sections as a dragged header crosses another header.
private struct CategoryReorderDropDelegate: DropDelegate {
    let target: ToolCategory
    let order: [ToolCategory]
    let dragging: ToolCategory?
    let move: ([ToolCategory]) -> Void
    let end: () -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        var next = order
        next.remove(at: from)
        guard let anchor = next.firstIndex(of: target) else { return }
        next.insert(dragged, at: from < to ? anchor + 1 : anchor)
        move(next)
    }

    func performDrop(info: DropInfo) -> Bool { end(); return true }
}

/// A container-level catch-all so a drag that ends in empty space (or is cancelled) still resets the
/// drag session — the per-tile/per-header delegates only fire on an actual target.
private struct DragSessionEndDelegate: DropDelegate {
    let end: () -> Void
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { end(); return true }
}

/// The glass + accent settings the dashboard tile and row both read. They sit outside a tool screen's
/// `\.toolAccent`, so they resolve the accent directly here. Wraps the shared `GlassAppearance` reader
/// and adds the accent-style preset that turns a tool + hue into that tool's dashboard accent — so the
/// tile and the row can't drift apart on how they read the appearance.
private struct DashboardTileChrome: DynamicProperty {
    private let glass = GlassAppearance()
    @AppStorage(LiquidGlass.accentStyleKey) private var accentStyleRaw: String = AccentStyle.multicolor.rawValue

    var level: GlassLevel { glass.level }
    var hue: LiquidGlassHue { glass.hue }
    var tint: Double { glass.tint }
    func accent(for tool: Tool) -> Color {
        (AccentStyle(rawValue: accentStyleRaw) ?? .multicolor).accent(for: tool, hue: glass.hue)
    }
}

/// The accent-tinted diagonal gradient behind a dashboard icon plate — brighter in dark so the plate
/// reads as lit glass, softer in light. Shared by the tile's 92-pt header plate and the row's 40-pt one.
private func dashboardAccentPlateGradient(_ accent: Color, dark: Bool) -> LinearGradient {
    LinearGradient(
        colors: dark ? [accent.opacity(0.64), accent.opacity(0.27)]
                     : [accent.opacity(0.30), accent.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private extension View {
    /// The identical glass surface the tile and the row wrap their content in: the whole shape is the
    /// hit target, the accent tint washes behind, then the window's glass material clips to the shape.
    /// Only the corner radius differs between the two (tile vs row tier); the hover/idle border,
    /// specular, and shadow stay per-view because those genuinely diverge.
    func dashboardTileGlass(cornerRadius: CGFloat, level: GlassLevel, hue: LiquidGlassHue, tint: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .contentShape(shape)
            .contentSurface(hue: hue, tint: tint)
            .clipShape(shape)
            .glassSurface(level, cornerRadius: cornerRadius)
    }
}

struct ToolTileView: View {
    let tool: Tool
    /// Cards mode: each tile is an elevated floating card. Unified: tiles read as one flat surface.
    var floating: Bool = true
    /// Whether this tool is pinned — drives the filled pin glyph shown even without hover.
    var isPinned: Bool = false
    /// Pin/unpin action. `nil` hides the pin button entirely (e.g. search results).
    var onTogglePin: (() -> Void)? = nil
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { scheme == .dark }

    private let chrome = DashboardTileChrome()
    /// The tile's effective accent under the chosen accent-style preset (the dashboard sits outside the
    /// tool screen's `\.toolAccent`, so it resolves here directly).
    private var accent: Color { chrome.accent(for: tool) }

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
                    .fill(dashboardAccentPlateGradient(accent, dark: dark))
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
            // The hover "Open" cue is accent-as-text; route it through the appearance-adjusted accent
            // so it clears contrast against the tile surface in both light and dark.
            .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
            .opacity(hovered ? 1 : 0)
            .offset(x: hovered ? 0 : -4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        // Whole tile is the tap target (the glass background isn't part of the NavigationLink's hit
        // region on its own), the Tint slider washes it like the tool cards, then the window's glass
        // material clips to the rounded shape — Clear shows the desktop through, Frosted blurs, Solid
        // stays opaque. Shared with the row (only the radius differs).
        .dashboardTileGlass(cornerRadius: LiquidGlass.tileRadius, level: chrome.level, hue: chrome.hue, tint: chrome.tint)
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlass.tileRadius, style: .continuous)
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
                RoundedRectangle(cornerRadius: LiquidGlass.tileRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.40), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
            }
        }
        .overlay(alignment: .topTrailing) { pinButton }
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
        .scaleEffect(hovered && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.title). \(tool.subtitle)\(isPinned ? ". Pinned" : "")")
    }

    /// The hover-revealed pin toggle, top-trailing. Visible whenever the tile is hovered *or* pinned,
    /// so a pinned tile always shows its filled pin as an at-a-glance marker. Hit-testing stays on
    /// regardless of visibility — on a trackpad the pointer's presence is what reveals it, so there's
    /// no invisible-but-clickable target the way the old hover arrows had. Its own accessibility is
    /// hidden because the enclosing tile exposes Pin/Unpin as a named action instead.
    @ViewBuilder
    private var pinButton: some View {
        if let onTogglePin {
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
                    .frame(width: 24, height: 24)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isPinned || hovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .help(isPinned ? "Unpin from top" : "Pin to top")
            .accessibilityHidden(true)
            .padding(10)
        }
    }
}

/// The compact table row for the List layout: a small accent icon plate, the tool's title and
/// one-line subtitle, an optional pin toggle, and a trailing chevron. Reads the same glass/accent
/// settings as `ToolTileView` (directly, since the dashboard sits outside the tool screen's
/// `\.toolAccent`) so the List mode honors Multicolor/Single, the glass level, and the tint wash
/// exactly like the tiles do.
struct ToolRowView: View {
    let tool: Tool
    /// Cards mode lifts each row with a soft shadow; Unified keeps them flat, like a plain table.
    var floating: Bool = true
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private let chrome = DashboardTileChrome()
    private var accent: Color { chrome.accent(for: tool) }

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
            pinButton
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(hovered ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Whole row is the hit target (the glass fill isn't part of the NavigationLink's region alone).
        .dashboardTileGlass(cornerRadius: LiquidGlass.rowRadius, level: chrome.level, hue: chrome.hue, tint: chrome.tint)
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius, style: .continuous)
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
        .accessibilityLabel("\(tool.title). \(tool.subtitle)\(isPinned ? ". Pinned" : "")")
    }

    private var iconPlate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dashboardAccentPlateGradient(accent, dark: dark))
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

    /// The row's pin toggle: shown whenever hovered or pinned, mirroring the tile's affordance. Its own
    /// accessibility is hidden; the enclosing row exposes Pin/Unpin as a named action.
    @ViewBuilder
    private var pinButton: some View {
        if let onTogglePin {
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isPinned ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isPinned || hovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .help(isPinned ? "Unpin from top" : "Pin to top")
            .accessibilityHidden(true)
        }
    }
}
