import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ReorderItem: Identifiable, Equatable {
    /// Stable identity = the page's position in the original document (zero-based). No image:
    /// rows and preview cells both demand-render through the shared LRU, keyed by this index.
    let id: Int
    var originalIndex: Int { id }
    var pageNumber: Int { id + 1 }
}

/// The Reorder tool's working set as a pure value: the pages kept (in output order) and the pages
/// removed (held sorted by original index so the "Removed" list is stable regardless of removal
/// order). Every index transform the view performs — drag-move, remove, restore, restore-all, reset
/// — lives here as a pure mutation, so the math is unit-testable without standing up SwiftUI. The
/// view holds one of these as @State and renders straight from it.
struct ReorderWorkingSet: Equatable {
    /// Pages kept, in output order — what "Reorder & save…" writes and what the preview shows.
    private(set) var items: [ReorderItem] = []
    /// Pages removed from the output, kept (with their originals) so any can be restored. Sorted by
    /// original index for a stable "Removed" list.
    private(set) var removed: [ReorderItem] = []

    init() {}

    /// A fresh working set for a `pageCount`-page document: every page kept, in original order.
    init(pageCount: Int) {
        items = (0..<max(0, pageCount)).map { ReorderItem(id: $0) }
    }

    /// True once the working set differs from the untouched document — a page was removed, or the
    /// kept pages are no longer in their original order.
    var isModified: Bool {
        if !removed.isEmpty { return true }
        return items.enumerated().contains { $0.offset != $0.element.originalIndex }
    }

    /// Every page removed: there is nothing to write, so saving is blocked until one is restored.
    var allPagesRemoved: Bool {
        items.isEmpty && !removed.isEmpty
    }

    /// Relocate the kept pages at `source` offsets to `destination`, mirroring SwiftUI `.onMove`.
    /// `destination` is already an original-coordinate insertion point — the grid drop delegate has
    /// applied the `to > from ? to + 1 : to` off-by-one via `gridReorderDestination(from:to:)`.
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Remove the kept page with this 1-based original page number (the badge the grid shows),
    /// parking it — sorted — in `removed` so it can be restored. No-op if it isn't currently kept.
    mutating func remove(originalPageNumber: Int) {
        guard let item = items.first(where: { $0.pageNumber == originalPageNumber }) else { return }
        remove(item)
    }

    /// Excludes a page from the output, keeping it (sorted by original index) so it can be restored.
    mutating func remove(_ item: ReorderItem) {
        guard let index = items.firstIndex(of: item) else { return }
        let removedItem = items.remove(at: index)
        let insertAt = removed.firstIndex { $0.originalIndex > removedItem.originalIndex } ?? removed.count
        removed.insert(removedItem, at: insertAt)
    }

    /// Puts one removed page back at the end of the kept order; the user can drag it from there.
    mutating func restore(_ item: ReorderItem) {
        guard let index = removed.firstIndex(of: item) else { return }
        items.append(removed.remove(at: index))
    }

    /// Brings every removed page back, appended in ascending original order so it reads predictably.
    mutating func restoreAll() {
        guard !removed.isEmpty else { return }
        items.append(contentsOf: removed.sorted { $0.originalIndex < $1.originalIndex })
        removed = []
    }

    /// Back to the untouched document: every page present, in original order.
    mutating func reset() {
        items = (items + removed).sorted { $0.originalIndex < $1.originalIndex }
        removed = []
    }
}

struct ReorderToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    /// The pages kept (in output order) and the pages removed. All the reorder/remove/restore/reset
    /// index math lives on this value type so it can be unit-tested away from SwiftUI; the list, the
    /// preview, and the exported copy all follow `working.items`.
    @State private var working = ReorderWorkingSet()
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "reordered.pdf"
    @State private var isDropTargeted = false
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    /// `<path>@<mtime>` of the loaded file, captured once per load — the prefix every row's and
    /// preview cell's cache key shares.
    @State private var fileKeyBase = ""

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    /// The right-hand preview, in the current arrangement. The spec id is the page's ORIGINAL
    /// 1-based number — the badge the drop-pages design promises ("labels show each page's
    /// original number"), unique within any arrangement, and a stable SwiftUI identity so a drag
    /// moves cells instead of rebuilding them. The cache key carries the same original index, so
    /// reordering (or restoring a dropped page) is pure cache hits — no re-render.
    private var previewSpecs: [PreviewPageSpec] {
        working.items.map { item in
            PreviewPageSpec(id: item.originalIndex + 1, cacheKey: "\(fileKeyBase)#\(item.originalIndex)")
        }
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            SinglePDFPreviewColumn(
                pages: previewSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "The pages you keep, in the new order (labels show each page's original number).",
                emptyTitle: working.allPagesRemoved ? "All pages removed" : "No PDF selected",
                emptySubtitle: working.allPagesRemoved
                    ? "Restore a page on the left to preview it."
                    : "Drop a PDF here or choose one to arrange its pages.",
                emptySystemImage: "arrow.up.arrow.down.square",
                onDeletePage: { pageNumber in working.remove(originalPageNumber: pageNumber) },
                deletePageHelp: "Leave this page out of the saved copy",
                deletePageAccessibilityLabel: { "Leave page \($0) out of the saved copy" },
                onMovePages: { source, destination in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        working.moveItems(fromOffsets: source, toOffset: destination)
                    }
                },
                reorderHint: "Drag pages to reorder; the badge stays each page's original number.",
                render: { spec in
                    guard let url = inputURL else { return nil }
                    // The key's `#<n>` suffix is the ORIGINAL page index (position-independent),
                    // so a render started just before a drag still fetches its own cell's page.
                    guard let index = spec.cacheKey.split(separator: "#").last.flatMap({ Int($0) }) else {
                        return nil
                    }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: index))?.image
                }
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                inputURL = urls.first
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: suggestedName.exportFilenameStem
        ) { result in
            let savedBytes = exportDoc?.data.count
            exportDoc = nil
            switch result {
            case .success(let url):
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.reorder.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.reorder.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
        // Reordering, removing, or restoring a page changes the very arrangement the receipt vouches
        // for, so "Reordered N pages in the new order" goes stale. ReorderWorkingSet is Equatable, so
        // one clear covers every kind of edit to the order.
        .onChange(of: working) { _, _ in saveSummary = nil }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        // ScrollView wrapper like every other single-file tool: without it, the controls stack
        // (file card + guidance + the removed-pages list) overflows UP into the tool header at the
        // min window height instead of scrolling. The action bar stays pinned below the scroll.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        headerRow

                        Group {
                            if inputURL == nil {
                                emptyDropZone
                            } else if let url = inputURL {
                                loadedControls(url: url)
                            }
                        }
                        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }
                    }
                    .padding(18)
                    .formCard()

                    if let saveSummary {
                        ToolSaveBanner(accent: accent, summary: saveSummary)
                    }
                }
                .padding(12)
            }

            Divider()

            RunActionButton(title: "Reorder & save…", busy: busy, canRun: !working.items.isEmpty) {
                Task { await runReorder() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.square")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("Pages")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil, working.isModified {
                        Button("Reset") { working.reset() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Restore the original order and bring back removed pages")
                    }
                    if inputURL != nil {
                        Button("Clear") { inputURL = nil }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Remove the selected file")
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(sidebarSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Drop a PDF or add a file. Drag its thumbnails on the right to set a new page order, and trash any you don't need."
        }
        return "Drag thumbnails on the right to rearrange. Trash a page to leave it out of the saved copy — your original file is untouched."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.square")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Its pages appear as thumbnails you can drag into any order — remove the ones you don't need.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDF…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5])
                )
                .foregroundStyle(isDropTargeted ? accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    /// The controls-only body once a file is loaded — the file card, then either the reorder guidance
    /// or (when every page is dropped) the all-removed notice, plus the "Removed" restore area. The
    /// pages themselves live only in the right-hand grid now; this pane holds no page list.
    private func loadedControls(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedFileCard(url: url)

            if isGeneratingPreviews && working.items.isEmpty && working.removed.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading pages…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                if working.allPagesRemoved {
                    allPagesRemovedNotice
                } else {
                    reorderGuidance
                }
                if !working.removed.isEmpty {
                    removedSection
                }
            }
        }
    }

    /// The loaded file at a glance — name and a kept/removed page count. Mirrors Delete Pages' card so
    /// Reorder's controls-only sidebar reads the same as the other single-PDF tools.
    private func selectedFileCard(url: URL) -> some View {
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
                if isGeneratingPreviews && working.items.isEmpty && working.removed.isEmpty {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(pageCountSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected file \(url.lastPathComponent)")
    }

    private var pageCountSummary: String {
        let kept = working.items.count
        if working.removed.isEmpty {
            return "\(kept) page\(kept == 1 ? "" : "s")"
        }
        return "\(kept) kept · \(working.removed.count) removed"
    }

    /// One-line explainer that the reorder interaction now lives in the right-hand grid, since the
    /// sidebar no longer shows the draggable page list.
    private var reorderGuidance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.body)
                .foregroundStyle(accent)
            Text("Drag the thumbnails on the right to set a new order. Trash any page to leave it out of the saved copy — your original file is untouched.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag the thumbnails on the right to reorder. Trash a page to leave it out of the saved copy.")
    }

    /// Shown when every page has been removed: saving is blocked, so point the user at the Restore
    /// controls right below instead of leaving them staring at an empty list.
    private var allPagesRemovedNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Every page is removed")
                .font(.callout.weight(.semibold))
            Text("Restore at least one page below to save. Nothing is written while the list is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Every page is removed. Restore at least one page to save.")
    }

    /// The "Removed (N)" area: mirrors Delete Pages' "from a copy" framing so removal never reads as
    /// touching the source, and offers a per-page and a bulk way back.
    private var removedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Removed (\(working.removed.count))", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Restore all") { working.restoreAll() }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Bring every removed page back into the list")
            }
            Text("Left out of the saved copy only — your original file is untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let rows = VStack(spacing: 6) {
                ForEach(working.removed) { item in
                    removedRow(for: item)
                }
            }
            // Bound the area so a document with many removed pages can't push the save bar off-screen.
            if working.removed.count > 5 {
                ScrollView { rows }
                    .frame(maxHeight: 176)
            } else {
                rows
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func removedRow(for item: ReorderItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Same demand-loaded thumbnail (and cache key) as the kept rows and the preview cells
            // — a page dropped after rendering once is a pure cache hit here.
            CachedThumbnailCell(cacheKey: "\(fileKeyBase)#\(item.originalIndex)", placeholder: .blank) {
                guard let url = inputURL else { return nil }
                return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: item.originalIndex))?.image
            }
            .frame(width: 26, height: 34)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .opacity(0.55)

            Text("Page \(item.pageNumber)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { working.restore(item) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(accent)
            .help("Add page \(item.pageNumber) back to the list")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Removed original page \(item.pageNumber)")
        .accessibilityHint("Restores this page to the list")
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        // A different (or removed) file: the last run's confirmation no longer describes what's loaded.
        saveSummary = nil
        guard let url = inputURL else {
            working = ReorderWorkingSet()
            isGeneratingPreviews = false
            return
        }
        // Clear the old document's rows BEFORE the await: `working.items` is what "Reorder & save…"
        // applies to the current `inputURL`, so leaving them populated while the new file's
        // thumbnails render lets a click apply document A's page order (and count) to document B —
        // silently truncating it to A's page count. Drop the removed set with it so removals typed
        // against document A can't carry over and silently omit pages from document B.
        working = ReorderWorkingSet()
        isGeneratingPreviews = true
        do {
            // Only the page count loads up front; row and preview cells render on demand.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            // `.task(id:)` cancelled this load if the user switched files again; a superseded load
            // must neither install its stale rows nor clear the spinner the newer load now owns.
            guard !Task.isCancelled else { return }
            fileKeyBase = PreviewPageSpec.fileKey(for: url)
            working = ReorderWorkingSet(pageCount: count)
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            working = ReorderWorkingSet()
            isGeneratingPreviews = false
            if case PDFOperationError.encryptedInput = error {
                // Locked selection: actionable message + back to the empty state (Metadata's pattern).
                alertMessage = error.localizedDescription
                inputURL = nil
            }
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            if let url = await NSItemProvider.firstResolvablePDFURL(from: providers) {
                inputURL = url
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runReorder() async {
        guard let fileURL = inputURL, !working.items.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        saveSummary = nil
        AppStateManager.shared.beginOperation(Tool.reorder.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.reorder.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-reordered.pdf"
        let order = working.items.map(\.originalIndex)

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.reorderData(inputURL: fileURL, order: order)
                }
            }
            let summary = ToolSaveSummary(
                title: "Reordered \(order.count) page\(order.count == 1 ? "" : "s")",
                detail: "Saved a copy in the new page order.",
                url: nil
            )
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.reorder.title,
                defaultStem: "reordered",
                suffixWord: "reordered"
            ) {
            case .savedBeside(let url):
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = summary
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.reorder.title) failed: \(error.localizedDescription)")
        }
    }
}

