import AppKit
import SwiftUI

/// Distinguishable per-file colors for the Split visual grid. Chosen to read as their own hue in both
/// light and dark (mid-tone, saturated enough for a 1.5-pt frame and a white-on-color label chip, muted
/// enough that a low-opacity fill stays a hint). Cycles if a document is cut into more files than colors.
enum SplitGroupPalette {
    static let colors: [Color] = [
        Color(red: 0.35, green: 0.42, blue: 0.92),  // indigo — leads, echoing the tool accent
        Color(red: 0.16, green: 0.63, blue: 0.60),  // teal
        Color(red: 0.86, green: 0.52, blue: 0.13),  // amber
        Color(red: 0.83, green: 0.33, blue: 0.52),  // rose
        Color(red: 0.36, green: 0.62, blue: 0.28),  // green
        Color(red: 0.55, green: 0.44, blue: 0.86),  // violet
        Color(red: 0.24, green: 0.58, blue: 0.87),  // blue
        Color(red: 0.78, green: 0.42, blue: 0.24),  // terracotta
    ]

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }

    /// A per-group border dash pattern for the Differentiate-Without-Color accommodation: solid,
    /// dashed, then dotted, cycling — so consecutive group frames are distinguishable by line style,
    /// not hue. An empty array is a solid stroke.
    static func borderDash(_ index: Int) -> [CGFloat] {
        switch ((index % 3) + 3) % 3 {
        case 1: return [7, 4]
        case 2: return [2, 4]
        default: return []
        }
    }
}

/// Right-hand preview for Split's visual grid: the document's pages, grouped into one colored frame per
/// output file with a "PDF N" label and page count, and scissor cut-markers in the gaps. It is a UI over
/// a `Set<Int>` of cut points (see ``SplitCuts``) — the same segments the text modes produce — so every
/// mode stays in sync with what the export writes.
///
/// **Interactive vs. reflective**: pass `onToggleCut` (Visual mode) and each gap becomes a click target —
/// a faint scissors on a page's trailing edge *adds* a cut after it; the solid scissors between two
/// groups *removes* that cut, merging them. Pass nil (the every-N reflection) and the same colored groups
/// render read-only, the between-group scissors shown as a static marker of where the setting cuts.
///
/// **Virtualized** like ``SinglePDFPreviewColumn``: cells hold no image state, reading the shared
/// ``PreviewThumbnailCache`` and rendering on demand through ``PDFPageThumbnailLoader`` (the PDF serial
/// queue), so a long document costs a screenful of thumbnails, not all of them.
struct SplitGroupedPreviewColumn: View {
    /// Every page of the document, in order; `spec.id` is the 1-based page number.
    let pages: [PreviewPageSpec]
    let isGenerating: Bool
    @Binding var thumbnailSize: CGFloat
    let accent: Color
    /// 1-based cut points ("cut after page k"). Drives the grouping; derived from the active mode.
    let cuts: Set<Int>
    /// Toggles the cut after a given 1-based page. Non-nil enables the interactive markers (Visual mode);
    /// nil renders the groups read-only (the every-N reflection).
    let onToggleCut: ((Int) -> Void)?
    var previewSubtitle: String
    var emptyTitle: String
    var emptySubtitle: String
    var emptySystemImage: String = "scissors"

    /// Produces one cell's image off the main actor (via the loader's serial queue). Runs when a cell
    /// appears and its key misses the shared cache.
    let render: (PreviewPageSpec) async -> NSImage?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var isInteractive: Bool { onToggleCut != nil }

    /// The pages split into consecutive groups at the cut boundaries — one group per output file,
    /// sharing ``SplitCuts/segments(pageCount:cuts:)``' cut math so the grid can never disagree with
    /// what the export writes. Cells keep their stable `spec.id`, so re-grouping after a cut is pure
    /// cache hits, never a re-render.
    private var groups: [[PreviewPageSpec]] {
        SplitCuts.groups(pages, cuts: cuts)
    }

    var body: some View {
        Group {
            if !pages.isEmpty || isGenerating {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                        .opacity(0.35)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let groups = groups
                            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                                groupCard(group, index: index)
                                if index < groups.count - 1 {
                                    cutDivider(afterPage: group.last?.id ?? 0)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            } else {
                EmptyStateView(
                    icon: emptySystemImage,
                    title: emptyTitle,
                    message: emptySubtitle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Preview")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if isGenerating {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            Text(previewSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isInteractive {
                Label(
                    "Click a scissors between pages to start a new file there; click a cut to merge.",
                    systemImage: "scissors"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            thumbnailSizeControl
        }
        .padding(18)
    }

    private var thumbnailSizeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thumbnail size")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .center, spacing: 10) {
                Text("S")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
                Slider(value: $thumbnailSize, in: 60...240)
                    .controlSize(.regular)
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.45 : 1)
                Text("L")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
            }
            Text("\(Int(thumbnailSize)) pt")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .padding(14)
        .frame(maxWidth: 360, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlass.innerCardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thumbnail size, \(Int(thumbnailSize)) points")
    }

    // MARK: - Group card

    /// One output file: a colored frame with a "PDF N" label, its page count, and a sub-grid of its
    /// pages. Every page but the group's last carries an "add a cut after me" scissors (the group's last
    /// page is already followed by the between-group divider), so a single card can be split in two.
    private func groupCard(_ group: [PreviewPageSpec], index: Int) -> some View {
        let color = SplitGroupPalette.color(index)
        let lastID = group.last?.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("PDF \(index + 1)")
                    .font(.caption.weight(.bold))
                    // Legible ink for the group's own fill color, not a fixed white that vanishes on
                    // the lighter palette entries (amber/terracotta).
                    .foregroundStyle(Color.onFillLabel(color))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color)
                    .clipShape(Capsule())
                Spacer(minLength: 8)
                Text("\(group.count) page\(group.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 16)],
                spacing: 16
            ) {
                ForEach(group) { spec in
                    SplitGroupCell(
                        spec: spec,
                        groupColor: color,
                        thumbnailSize: thumbnailSize,
                        accent: accent,
                        // Cutting after the group's own last page is the between-group divider's job.
                        onCut: (isInteractive && spec.id != lastID) ? { onToggleCut?(spec.id) } : nil,
                        render: render
                    )
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius, style: .continuous)
                .fill(color.opacity(0.08))
        }
        .overlay {
            // When the user asks not to rely on color alone, give each consecutive group frame a
            // distinct line style (solid / dashed / dotted, cycling) so adjacent files are told apart
            // by their border, not just by hue — the "PDF N" chip already names them.
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius, style: .continuous)
                .strokeBorder(
                    color.opacity(0.55),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: differentiateWithoutColor ? SplitGroupPalette.borderDash(index) : []
                    )
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File \(index + 1), \(group.count) page\(group.count == 1 ? "" : "s")")
    }

    // MARK: - Cut divider (between groups)

    /// The gap between two output files. Interactive: the scissors removes the cut after `page`, merging
    /// the two files. Read-only (every-N reflection): the scissors is a static marker of where the
    /// setting cuts.
    private func cutDivider(afterPage page: Int) -> some View {
        HStack(spacing: 10) {
            dividerLine
            if let onToggleCut {
                Button {
                    onToggleCut(page)
                } label: {
                    scissorsPill(active: true)
                }
                .buttonStyle(.plain)
                .help("Merge these two files (remove the cut after page \(page))")
                .accessibilityLabel("Cut after page \(page). Remove to merge these two files.")
            } else {
                scissorsPill(active: true)
                    .accessibilityLabel("Cut after page \(page)")
            }
            dividerLine
        }
        .padding(.vertical, 12)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(accent.opacity(isInteractive ? 0.35 : 0.22))
            .frame(height: 1.5)
    }

    /// The scissors chip shown at an active cut. Accent-filled when interactive (a real click target);
    /// a quieter outline when it merely reflects an every-N setting.
    private func scissorsPill(active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "scissors")
            Text("Cut")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(isInteractive ? Color.white : accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(isInteractive ? AnyShapeStyle(accent) : AnyShapeStyle(accent.opacity(0.12)))
        }
        .overlay {
            Capsule().strokeBorder(accent.opacity(isInteractive ? 0 : 0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isInteractive ? 0.18 : 0), radius: 2, y: 1)
    }
}

/// One page thumbnail inside a group card: the page image (framed in its group's color), a page-number
/// badge tinted to the group, and — when the card can be split here — a trailing scissors that adds a
/// cut after this page. Holds its own hover state so the scissors brightens under the cursor; holds no
/// image state (that lives in the shared cache).
private struct SplitGroupCell: View {
    let spec: PreviewPageSpec
    let groupColor: Color
    let thumbnailSize: CGFloat
    let accent: Color
    /// Non-nil when a cut can be added after this page (interactive mode, not the group's last page).
    let onCut: (() -> Void)?
    let render: (PreviewPageSpec) async -> NSImage?

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedThumbnailCell(cacheKey: spec.cacheKey) { await render(spec) }
                .frame(width: thumbnailSize)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.chipRadius, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidGlass.chipRadius, style: .continuous)
                        .strokeBorder(groupColor.opacity(0.6), lineWidth: 1.5)
                }

            Text("\(spec.id)")
                .font(.caption.weight(.bold))
                // Legible ink for the group's fill, not a fixed white that fails on the light entries.
                .foregroundStyle(Color.onFillLabel(groupColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(groupColor)
                .clipShape(Capsule())
                .padding(6)
        }
        .overlay(alignment: .trailing) {
            if let onCut {
                cutHandle(onCut)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(spec.id)")
    }

    /// The "start a new file after page N" scissors, riding the page's trailing edge so it reads as a cut
    /// along that seam. Always present (faintly) so the cut points are discoverable; fills with accent
    /// under the cursor.
    private func cutHandle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "scissors")
                .font(.caption.weight(.bold))
                .foregroundStyle(hovering ? Color.white : accent)
                .padding(6)
                .background {
                    Circle().fill(hovering ? AnyShapeStyle(accent) : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay {
                    Circle().strokeBorder(accent.opacity(hovering ? 0 : 0.55), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 3)
        .onHover { hovering = $0 }
        .help("Start a new file after page \(spec.id)")
        .accessibilityLabel("Cut after page \(spec.id)")
        .accessibilityHint("Starts a new file after this page")
    }
}

