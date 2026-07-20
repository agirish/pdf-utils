import SwiftUI

public struct ToolDetailView: View {
    public let tool: Tool
    @EnvironmentObject private var settings: SettingsPresenter
    @EnvironmentObject private var help: HelpPresenter
    @Environment(\.openWindow) private var openWindow

    @AppStorage(LiquidGlass.accentStyleKey) private var accentStyleRaw: String = AccentStyle.multicolor.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue

    /// The tool's effective accent under the chosen accent style — injected into `\.toolAccent` so the
    /// header, the primary button, and every accent surface in the tool track the Settings preset.
    private var resolvedAccent: Color {
        let style = AccentStyle(rawValue: accentStyleRaw) ?? .multicolor
        let hue = LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue
        return style.accent(for: tool, hue: hue)
    }

    public init(tool: Tool) {
        self.tool = tool
    }

    public var body: some View {
        VStack(spacing: 0) {
            ToolScreenHeader(tool: tool)
            Group {
                switch tool {
                case .compress:
                    CompressToolView()
                case .rotate:
                    RotateToolView()
                case .merge:
                    MergeToolView()
                case .split:
                    SplitToolView()
                case .extract:
                    ExtractToolView()
                case .reorder:
                    ReorderToolView()
                case .deletePages:
                    DeletePagesToolView()
                case .watermark:
                    WatermarkToolView()
                case .redact:
                    RedactToolView()
                case .fillSign:
                    FillSignToolView()
                case .protect:
                    ProtectToolView()
                case .metadata:
                    MetadataToolView()
                case .imagesToPdf:
                    ImagesToPDFToolView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Every accent surface in the tool — the header plate, drop zones, badges, and the primary
        // button — reads this, so the accent style preset (multicolor / single / monochrome) applies
        // uniformly across the whole screen.
        .environment(\.toolAccent, resolvedAccent)
        .background(DashboardBackground())
        .navigationTitle(tool.title)
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
                    help.openTool(tool)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help for this tool")
                .accessibilityLabel("Help")
            }
        }
        // Remember the tool in view so "Reopen last tool on launch" (Files settings) can restore it.
        .onAppear {
            UserDefaults.standard.set(tool.rawValue, forKey: SettingsKeys.lastToolUsed)
        }
    }
}
