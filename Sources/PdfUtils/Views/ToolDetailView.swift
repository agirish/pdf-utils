import SwiftUI

struct ToolDetailView: View {
    let tool: Tool

    var body: some View {
        Group {
            switch tool {
            case .compress:
                CompressToolView()
            case .rotate:
                RotateToolView()
            case .merge, .extract, .deletePages:
                toolPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardBackground())
        .navigationTitle(tool.title)
    }

    private var toolPlaceholder: some View {
        ContentUnavailableView {
            Label(tool.title, systemImage: tool.symbolName)
        } description: {
            Text(
                "This tool is not wired up yet. Upcoming commits will add PDF processing here."
            )
            .multilineTextAlignment(.center)
        }
    }
}
