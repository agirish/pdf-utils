import SwiftUI

/// In-content hero for each tool: icon, title, and a short explanation.
struct ToolScreenHeader: View {
    let tool: Tool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tool.accent.opacity(0.18))
                    .frame(width: 52, height: 52)
                Image(systemName: tool.symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tool.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(tool.title)
                    .font(.title2.weight(.semibold))
                Text(tool.headerDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.title). \(tool.headerDescription)")
    }
}
