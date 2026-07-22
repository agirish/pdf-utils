import SwiftUI

// The three sidebar "file chrome" pieces every single-file PDF tool drew for itself — a header row,
// an empty-state drop zone, and a selected-file card. The layout was byte-identical across Extract,
// Delete, Split, OCR, Metadata, Crop, Fill & Sign, Redact, and Reorder; only per-tool copy (the icon
// and a sentence or two) differed. Shared here as data-driven views so a change to the file chrome
// lands once instead of nine times. Tools that queue multiple files (Merge) or take images (Images to
// PDF), and the batch `UnifiedFilePanel`, keep their own chrome — their file model genuinely differs.

/// The sidebar header: tool icon, "PDF file" title, a Clear button (only with a file loaded), an Add
/// button, and a one-line subtitle beneath.
struct FileSidebarHeader: View {
    let accent: Color
    let icon: String
    var title: String = "PDF file"
    let subtitle: String
    /// True when a file is loaded — reveals the Clear button.
    let hasFile: Bool
    var addTitle: String = "Add PDF…"
    let onClear: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if hasFile {
                        Button("Clear", action: onClear)
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Remove the selected file")
                    }
                    Button(addTitle, action: onAdd)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The empty-state drop target: a large tool icon, the "Drop a PDF here or add a file" prompt, a
/// tool-specific descriptive line, and a Choose button, inside a dashed border that thickens and takes
/// the accent while a drag hovers.
struct EmptyFileDropZone: View {
    let accent: Color
    let icon: String
    var title: String = "Drop a PDF here or add a file"
    let description: String
    /// The drag-over highlight the host tracks on its own `.onDrop(isTargeted:)`.
    var isTargeted: Bool = false
    var chooseTitle: String = "Choose PDF…"
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button(chooseTitle, action: onChoose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [7, 5])
                )
                .foregroundStyle(isTargeted ? accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }
}

/// The loaded-file card: a doc glyph on an accent plate, the filename, and a "Loading preview…" /
/// "N pages" subline.
struct SelectedFileCard: View {
    let accent: Color
    let url: URL
    /// Shows "Loading preview…" while the page count is still resolving.
    var isLoadingPreview: Bool = false
    /// Resolved page count; `0` (or unknown) while loading, shown as "N pages" once known.
    var pageCount: Int = 0

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if isLoadingPreview {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else if pageCount > 0 {
                    Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlass.innerCardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlass.innerCardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected file \(url.lastPathComponent)")
    }
}
