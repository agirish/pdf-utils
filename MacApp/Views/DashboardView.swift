import SwiftUI
import PdfToolkit

struct DashboardView: View {
    @EnvironmentObject private var settings: SettingsPresenter
    @Environment(\.openWindow) private var openWindow
    @State private var showHelp = false

    @AppStorage(LiquidGlass.surfaceStyleKey)
    private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue

    private var floatingTiles: Bool {
        (SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified) == .cards
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(Tool.allCases) { tool in
                            NavigationLink(value: tool) {
                                ToolTileView(tool: tool, floating: floatingTiles)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            dashboardFooter
        }
        .background(DashboardBackground())
        .navigationTitle(AppBrand.displayName)
        .navigationDestination(for: Tool.self) { tool in
            // Re-inject the presenter so ToolDetailView's toolbar gear can open the overlay.
            ToolDetailView(tool: tool)
                .environmentObject(settings)
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
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("About \(AppBrand.displayName) and toolbar controls")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $showHelp) {
            DashboardHelpSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.largeTitle.weight(.semibold))
            Text("Pick a tool to work on your PDFs. Use the toolbar “?” for an overview of the window controls.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: 680, alignment: .leading)
            privacyBadge
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The "processing stays on your Mac" reassurance, lifted out of the intro sentence into a compact
    /// trust chip — a lock glyph and a faint green capsule read as "private/safe" at a glance.
    private var privacyBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
            Text("Files stay on your Mac — nothing is uploaded")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.green.opacity(0.10)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.green.opacity(0.24), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Privacy: files stay on your Mac, nothing is uploaded")
    }

    /// A slim status bar pinned to the window's bottom edge: gives the tall dashboard visual closure
    /// and a quiet home for the app identity and tool count.
    private var dashboardFooter: some View {
        HStack(spacing: 8) {
            Text(AppBrand.displayName)
                .fontWeight(.semibold)
            if let version = appVersion {
                Text("v\(version)")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(Tool.allCases.count) tools")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
    }

    private var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
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
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }

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
                                ? [tool.accent.opacity(0.64), tool.accent.opacity(0.27)]
                                : [tool.accent.opacity(0.30), tool.accent.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 92)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tool.accent.opacity(dark ? 0.60 : 0.22), lineWidth: 1)
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
                    .foregroundStyle(tool.accent)
                    .shadow(color: tool.accent.opacity(hovered ? 0.35 : 0), radius: 6)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(tool.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(tool.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Text("Open")
                Image(systemName: "arrow.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tool.accent)
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
                    hovered ? tool.accent.opacity(0.6)
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
