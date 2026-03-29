import SwiftUI

struct ToolDetailView: View {
    let tool: Tool
    @State private var showHelp = false

    var body: some View {
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
                case .extract:
                    ExtractToolView()
                case .deletePages:
                    DeletePagesToolView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashboardBackground())
        .navigationTitle(tool.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
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
        .sheet(isPresented: $showHelp) {
            ToolHelpSheet(tool: tool)
        }
    }
}
