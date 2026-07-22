import SwiftUI

/// The shared "done" screen for tools whose result is worth confirming on its own — Merge combines
/// many files into one, Split fans one file into a folder. Both used to roll their own success screen
/// that disagreed on layout, stats, and actions; this is the single one they share.
///
/// Single-file tools that route through the save dialog deliberately do NOT use this: that dialog,
/// plus the Files → "After exporting" action, is their confirmation. Forcing a full-screen success
/// pane after a one-file save would just replace the form the user is about to reuse.
struct ToolSuccessView: View {
    /// One labelled metric in the summary row (e.g. value "12", label "pages").
    struct Stat: Identifiable {
        let id = UUID()
        let value: String
        let label: String

        init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The tool's accent, tinting the primary "Do another" button like every tool's Run button.
    let accent: Color
    let title: String
    /// The saved location, shown truncated under the title.
    let path: String
    /// Optional summary metrics; an empty array hides the row.
    var stats: [Stat] = []
    /// Reveals the produced file(s) in Finder.
    let onShowInFinder: () -> Void
    /// Resets the tool to run again.
    let onDoAnother: () -> Void

    var body: some View {
        ToolFormContainer {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 46))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !stats.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(stats) { stat in
                            statTile(stat)
                        }
                    }
                    .padding(.top, 6)
                }

                HStack(spacing: 12) {
                    Button("Show in Finder", action: onShowInFinder)
                        .controlSize(.large)
                    Button("Do another", action: onDoAnother)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(accent)
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statTile(_ stat: Stat) -> some View {
        VStack(spacing: 4) {
            Text(stat.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 78)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlass.innerCardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlass.innerCardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
