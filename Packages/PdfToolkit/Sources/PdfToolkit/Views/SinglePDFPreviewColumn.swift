import SwiftUI
import UniformTypeIdentifiers

/// Right-hand preview column for tools that show page thumbnails (Merge, Compress, Rotate, Extract, Delete).
///
/// **Virtualized**: callers describe pages as ``PreviewPageSpec``s (cheap — a number and a cache
/// key) and supply a `render` closure; each cell renders on demand as it appears and the images
/// live only in the shared ``PreviewThumbnailCache`` LRU, so a 500-page document costs a screenful
/// of thumbnails, not 500. Reordering rows reuses cached cells by key instead of re-rendering.
///
/// Page selection is opt-in and additive: pass `selectedPages` + `onTogglePage` (Split's custom
/// ranges, Extract) to turn each thumbnail into a click-to-toggle target with a selection check.
/// Both default to nil, so every other caller renders and behaves exactly as before.
struct SinglePDFPreviewColumn: View {
    let pages: [PreviewPageSpec]
    let isGenerating: Bool
    @Binding var thumbnailSize: CGFloat
    let accent: Color
    var previewSubtitle: String
    var emptyTitle: String
    var emptySubtitle: String
    var emptySystemImage: String = "doc.fill"

    /// 1-based page numbers currently selected. nil disables the whole selection layer (the default),
    /// so the thumbnails render as plain, non-interactive previews for tools that don't opt in.
    var selectedPages: Set<Int>? = nil
    /// Invoked with a 1-based page number when its thumbnail is clicked. Only consulted when
    /// `selectedPages` is non-nil.
    var onTogglePage: ((Int) -> Void)? = nil
    /// Optional one-line hint shown under the subtitle while selecting, explaining what a click does.
    var selectionPrompt: String? = nil

    /// Invoked with a cell's 1-based display number to *remove* that page from the preview (Merge's
    /// inline page-drop, Reorder's per-page drop). When non-nil, each thumbnail gains a small trash
    /// button. Independent of the selection layer above — a caller sets this and leaves
    /// `selectedPages`/`onTogglePage` nil, so the pages render as plain previews that can each be dropped.
    var onDeletePage: ((Int) -> Void)? = nil

    /// Reorders pages by dragging thumbnails: mirrors SwiftUI `.onMove(from:to:)` applied over `pages`.
    /// When non-nil, every thumbnail becomes draggable and the grid live-reorders as a drag crosses
    /// cells (the Reorder tool). Independent of the selection/delete layers; default nil leaves every
    /// other caller a plain, non-draggable preview exactly as before.
    var onMovePages: ((IndexSet, Int) -> Void)? = nil
    /// Optional one-line hint shown under the subtitle when reordering is enabled, explaining the drag.
    var reorderHint: String? = nil

    /// Produces one cell's image off the main actor (PDF pages via the loader's serial queue,
    /// image files via ImageIO). Runs when a cell appears and its key misses the shared cache.
    var render: (PreviewPageSpec) async -> NSImage?

    /// The page id being dragged, captured when the drag starts and read on drop to know the source.
    /// Not tied to any lingering visual, so a cancelled drag leaves nothing stuck. Defaulted so it
    /// stays out of the synthesized memberwise init.
    @State private var draggingSpecID: Int? = nil
    /// The page id of the cell the drag is currently hovering — highlighted as the drop target, and
    /// cleared on exit or drop so it never persists.
    @State private var dropTargetID: Int? = nil

    var body: some View {
        Group {
            if !pages.isEmpty || isGenerating {
                VStack(alignment: .leading, spacing: 0) {
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

                        if let selectionPrompt {
                            Label(selectionPrompt, systemImage: "hand.tap")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let reorderHint {
                            Label(reorderHint, systemImage: "hand.draw")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

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
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Thumbnail size, \(Int(thumbnailSize)) points")
                    }
                    .padding(18)

                    Divider()
                        .opacity(0.35)

                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(pages) { spec in
                                reorderableCell(spec)
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

    // MARK: - Page cell

    /// Wraps ``pageCell`` with the drag-to-reorder layer when `onMovePages` is set (Reorder). The
    /// cell you drag over lifts as the drop target; the move is applied once, on drop — never during
    /// the drag, which is what keeps it reliable (mutating the grid mid-drag tears down the drop
    /// targets and the drop snaps back). A context menu gives the same moves (plus Remove) for
    /// keyboard/non-drag use. With `onMovePages` nil — every other caller — the cell is returned
    /// untouched, so nothing about their grids changes.
    @ViewBuilder
    private func reorderableCell(_ spec: PreviewPageSpec) -> some View {
        if let onMovePages {
            pageCell(spec)
                .scaleEffect(dropTargetID == spec.id && draggingSpecID != spec.id ? 1.06 : 1)
                .animation(.easeInOut(duration: 0.12), value: dropTargetID)
                .onDrag {
                    draggingSpecID = spec.id
                    // The payload identifies the dragged page; the drop reads `draggingSpecID`, so the
                    // string itself never has to be parsed back.
                    return NSItemProvider(object: "\(spec.id)" as NSString)
                } preview: {
                    dragPreview(spec)
                }
                .onDrop(
                    of: [.text],
                    delegate: GridReorderDropDelegate(
                        targetID: spec.id,
                        pages: pages,
                        draggingSpecID: $draggingSpecID,
                        dropTargetID: $dropTargetID,
                        onMove: onMovePages
                    )
                )
                .contextMenu { reorderMenu(spec) }
        } else {
            pageCell(spec)
        }
    }

    /// The floating image shown under the cursor mid-drag: the cell's cached thumbnail (it is on
    /// screen, so it is always a cache hit) at the current grid size, or a blank sheet as a fallback.
    private func dragPreview(_ spec: PreviewPageSpec) -> some View {
        Group {
            if let image = PreviewThumbnailCache.shared.image(for: spec.cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white.aspectRatio(8.5 / 11, contentMode: .fit)
            }
        }
        .frame(width: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Keyboard/non-drag fallback for reordering (drag is mouse-only). Offsets follow
    /// `Array.move(fromOffsets:toOffset:)`: to land after the right-hand neighbour the destination is
    /// `index + 2`. Also surfaces Remove when the caller opted into `onDeletePage`.
    @ViewBuilder
    private func reorderMenu(_ spec: PreviewPageSpec) -> some View {
        if let onMovePages, let index = pages.firstIndex(where: { $0.id == spec.id }) {
            Button("Move to Front") { onMovePages(IndexSet(integer: index), 0) }
                .disabled(index == 0)
            Button("Move Left") { onMovePages(IndexSet(integer: index), index - 1) }
                .disabled(index == 0)
            Button("Move Right") { onMovePages(IndexSet(integer: index), index + 2) }
                .disabled(index == pages.count - 1)
            Button("Move to End") { onMovePages(IndexSet(integer: index), pages.count) }
                .disabled(index == pages.count - 1)
        }
        if let onDeletePage {
            Divider()
            Button("Remove Page", role: .destructive) { onDeletePage(spec.id) }
        }
    }

    /// One thumbnail. When selection is opted into, it becomes a click-to-toggle button carrying a
    /// selection check and accent ring; otherwise it renders exactly as the plain preview always has.
    @ViewBuilder
    private func pageCell(_ spec: PreviewPageSpec) -> some View {
        if let selectedPages, let onTogglePage {
            let isSelected = selectedPages.contains(spec.id)
            Button {
                onTogglePage(spec.id)
            } label: {
                thumbnail(spec, selectable: true, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Page \(spec.id)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Toggles whether this page is included")
        } else {
            thumbnail(spec, selectable: false, isSelected: false)
        }
    }

    private func thumbnail(_ spec: PreviewPageSpec, selectable: Bool, isSelected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            PreviewCellImage(spec: spec, render: render)
                .frame(width: thumbnailSize)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .overlay {
                    if selectable && isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selectable {
                        selectionBadge(isSelected: isSelected)
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let onDeletePage {
                        deleteBadge(pageNumber: spec.id) { onDeletePage(spec.id) }
                            .padding(7)
                    }
                }

            Text("\(spec.id)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accent)
                .clipShape(Capsule())
                .padding(6)
        }
        // Selected pages stay opaque; unselected dim slightly so the chosen set reads at a glance.
        .opacity(!selectable || isSelected ? 1 : 0.72)
    }

    /// Top-right trash for a droppable thumbnail (Merge's inline page-drop). Carries its own dark disc
    /// so the glyph stays legible over any page, mirroring the unselected selection badge.
    private func deleteBadge(pageNumber: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .help("Leave this page out of the merged PDF")
        .accessibilityLabel("Drop page \(pageNumber) from the merge")
    }

    /// Top-left check for a selectable thumbnail. Both states carry their own backing disc so they
    /// stay legible over any page — a white page would otherwise swallow a plain glyph.
    @ViewBuilder
    private func selectionBadge(isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, accent)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }
}

/// One cell's image, read straight from the shared LRU in `body` — the cell holds NO image state
/// of its own, which is what keeps a long document's resident cost at the cache's cap instead of
/// one image per created cell. On a cache miss the task renders off-main, stores, and bumps `tick`
/// to repaint. Visible cells touch the LRU every body pass, so eviction only ever takes offscreen
/// entries.
private struct PreviewCellImage: View {
    let spec: PreviewPageSpec
    let render: (PreviewPageSpec) async -> NSImage?
    /// Repaint trigger after a store; the image itself deliberately lives only in the cache.
    @State private var tick = 0
    /// True once a render attempt finished — a page that can't render (a damaged or locked entry)
    /// shows a plain blank sheet instead of an eternal spinner.
    @State private var attempted = false

    var body: some View {
        Group {
            if let image = PreviewThumbnailCache.shared.image(for: spec.cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // US Letter aspect placeholder; the cell reflows to the true aspect when loaded.
                Color.white
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .overlay {
                        if !attempted {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .id(tick)
        .task(id: spec.cacheKey) {
            guard PreviewThumbnailCache.shared.image(for: spec.cacheKey) == nil else { return }
            attempted = false
            let rendered = await render(spec)
            guard !Task.isCancelled else { return }
            if let rendered {
                PreviewThumbnailCache.shared.store(rendered, for: spec.cacheKey)
            }
            attempted = true
            tick += 1
        }
    }
}

/// Reorders one page per drop. Crucially it does NOT mutate during the drag — hovering a cell only
/// lifts it as the drop target; the single `onMove` runs in `performDrop`. Reordering mid-drag would
/// rebuild the `LazyVGrid` and invalidate the drop targets, which is what made an earlier live-shuffle
/// version snap most drops back. The dragged page is tracked in `draggingSpecID` (set at drag start),
/// so the drop needs no async reading of the item payload.
private struct GridReorderDropDelegate: DropDelegate {
    let targetID: Int
    let pages: [PreviewPageSpec]
    @Binding var draggingSpecID: Int?
    @Binding var dropTargetID: Int?
    let onMove: (IndexSet, Int) -> Void

    /// Only accept our own reorder drags, never stray text dropped from elsewhere.
    func validateDrop(info: DropInfo) -> Bool { draggingSpecID != nil }

    func dropEntered(info: DropInfo) {
        if draggingSpecID != targetID { dropTargetID = targetID }
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingSpecID = nil
            dropTargetID = nil
        }
        guard let dragging = draggingSpecID,
              let from = pages.firstIndex(where: { $0.id == dragging }),
              let to = pages.firstIndex(where: { $0.id == targetID }) else { return false }
        // No-op drop onto itself still counts as handled, so the drag settles instead of snapping back.
        if from != to {
            // `Array.move`'s destination is an original-coordinate insertion point: landing after a
            // lower cell needs `to + 1`; landing before a higher cell is just `to`.
            withAnimation(.easeInOut(duration: 0.2)) {
                onMove(IndexSet(integer: from), to > from ? to + 1 : to)
            }
        }
        return true
    }
}
