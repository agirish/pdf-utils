import SwiftUI

public struct ToolDetailView: View {
    public let tool: Tool
    @EnvironmentObject private var settings: SettingsPresenter
    @State private var showHelp = false

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
                case .protect:
                    ProtectToolView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashboardBackground())
        .navigationTitle(tool.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                .help("Help for this tool")
                .accessibilityLabel("Help")
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .automatic)
        .sheet(isPresented: $showHelp) {
            ToolHelpSheet(tool: tool)
        }
    }
}
