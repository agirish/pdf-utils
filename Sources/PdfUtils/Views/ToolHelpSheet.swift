import SwiftUI

/// Sheet-style in-app help (common macOS pattern: “?” opens a focused explainer instead of a web page).
struct ToolHelpSheet: View {
    let tool: Tool
    @Environment(\.dismiss) private var dismiss

    private var content: ToolHelpContent { tool.helpContent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    labeledBlock(title: "Overview", body: content.overview)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("How to use")
                            .font(.headline)
                        ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1).")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(step)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Controls")
                            .font(.headline)
                        ForEach(Array(content.controls.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pair.0)
                                    .font(.subheadline.weight(.semibold))
                                Text(pair.1)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if !content.tips.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tips")
                                .font(.headline)
                            ForEach(Array(content.tips.enumerated()), id: \.offset) { _, tip in
                                Label {
                                    Text(tip)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundStyle(.yellow.opacity(0.9))
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(minWidth: 420, minHeight: 360)
            .navigationTitle("Help — \(tool.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func labeledBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
