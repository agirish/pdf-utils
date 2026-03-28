import SwiftUI

struct ToolDetailView: View {
    let tool: Tool

    var body: some View {
        ContentUnavailableView {
            Label(tool.title, systemImage: tool.symbolName)
        } description: {
            Text(
                "This screen is a placeholder. The next commits will connect each tool to on-device PDF processing."
            )
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardBackground())
        .navigationTitle(tool.title)
    }
}
