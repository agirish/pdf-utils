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
            case .merge:
                MergeToolView()
            case .extract:
                ExtractToolView()
            case .deletePages:
                DeletePagesToolView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardBackground())
        .navigationTitle(tool.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    FullScreenSupport.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Enter or exit full screen")
                .accessibilityLabel("Toggle full screen")
            }
        }
    }
}
