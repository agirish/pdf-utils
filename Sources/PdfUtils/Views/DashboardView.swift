import SwiftUI

struct DashboardView: View {
    @State private var showHelp = false

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Tool.allCases) { tool in
                        NavigationLink(value: tool) {
                            ToolTileView(tool: tool)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(32)
        }
        .background(DashboardBackground())
        .navigationTitle("pdf-utils")
        .navigationDestination(for: Tool.self) { tool in
            ToolDetailView(tool: tool)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("About pdf-utils and toolbar controls")
                .accessibilityLabel("Help")

            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .automatic)
        .sheet(isPresented: $showHelp) {
            DashboardHelpSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.largeTitle.weight(.semibold))
            Text("Pick a tool to work on your PDFs. Files stay on your Mac. Use the toolbar “?” for an overview of the window controls.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color.clear,
                    Color.purple.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct ToolTileView: View {
    let tool: Tool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tool.accent.opacity(0.18))
                    .frame(height: 88)
                Image(systemName: tool.symbolName)
                    .font(.system(size: 36, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tool.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 16 : 10, y: hovered ? 6 : 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.18), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.title). \(tool.subtitle)")
    }
}
