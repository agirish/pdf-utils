import AppKit
import SwiftUI

/// A one-line summary of what a finished single-file run produced, for ``ToolSaveBanner``.
struct ToolSaveSummary: Equatable {
    var title: String
    var detail: String
    /// The saved file, when known. The "beside original" path has it immediately; the save-dialog
    /// path fills it in from the exporter's success callback.
    var url: URL?
}

/// A compact inline confirmation for single-file tools whose result would otherwise save silently
/// (Protect, Clean Metadata). It's the lightweight sibling of Compress's before/after readout — a
/// checkmark, one line of what the run did, and a Reveal-in-Finder for the saved file. Destructive or
/// security-relevant saves especially deserve an explicit "this happened."
///
/// The caller owns the lifecycle: show it after a successful save, clear it when a new run starts or
/// the selected file changes.
struct ToolSaveBanner: View {
    let accent: Color
    let summary: ToolSaveSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                Text(summary.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = summary.url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .tint(accent)
                .help("Reveal the saved file in Finder")
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title). \(summary.detail)")
    }
}
