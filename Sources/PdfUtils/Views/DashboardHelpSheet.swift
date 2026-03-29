import SwiftUI

/// Explains the dashboard tiles and global shortcuts (shown from the home screen “?”).
struct DashboardHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(
                        "Each tile opens a tool that reads PDFs you choose and writes a new file through the system save sheet. Nothing is uploaded; processing stays on your Mac."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Toolbar")
                            .font(.headline)
                        Label {
                            Text("Full screen toggles the window in and out of macOS full-screen (same idea as View → Enter Full Screen).")
                        } icon: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .font(.subheadline)
                        Label {
                            Text("Help opens this panel on the dashboard, or a detailed guide for the tool you’re using.")
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
                        .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Settings")
                            .font(.headline)
                        Label {
                            Text("Open pdf-utils Settings (⌘,) for Liquid glass hue and strength, flat background modes, and the Merge PDF preview pane.")
                        } icon: {
                            Image(systemName: "gearshape")
                        }
                        .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tips")
                            .font(.headline)
                        Text("If a tool says it can’t access a file, pick it again with Choose… or Add PDFs… so macOS can grant access.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(minWidth: 400, minHeight: 280)
            .navigationTitle("About pdf-utils")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
