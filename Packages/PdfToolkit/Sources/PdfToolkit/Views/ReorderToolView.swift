import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct ReorderItem: Identifiable, Equatable {
    /// Stable identity = the page's position in the original document (zero-based). No image:
    /// rows and preview cells both demand-render through the shared LRU, keyed by this index.
    let id: Int
    var originalIndex: Int { id }
    var pageNumber: Int { id + 1 }
}

struct ReorderToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    /// The pages that will be written, in output order. Removing a page moves it out of here and
    /// into `removedItems`, so the list, the preview, and the exported copy all follow this array.
    @State private var items: [ReorderItem] = []
    /// Pages the user has removed. They are only left out of the exported copy — the source file is
    /// never touched — so they are kept here (with their rendered thumbnail) so any can be restored.
    /// Held sorted by original index for a stable "Removed" list regardless of removal order.
    @State private var removedItems: [ReorderItem] = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "reordered.pdf"
    @State private var isDropTargeted = false
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    @State private var selectedItemID: Int?
    /// `<path>@<mtime>` of the loaded file, captured once per load — the prefix every row's and
    /// preview cell's cache key shares.
    @State private var fileKeyBase = ""

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    /// True once the working set differs from the untouched document — either a page was removed or
    /// the kept pages are no longer in their original order. Drives the Reset affordance and the
    /// "you've changed something" affordances; a fresh load with nothing moved reads as unmodified.
    private var isModified: Bool {
        if !removedItems.isEmpty { return true }
        return items.enumerated().contains { $0.offset != $0.element.originalIndex }
    }

    /// Every page has been removed: there is nothing to write, so saving is blocked until at least
    /// one page is restored.
    private var allPagesRemoved: Bool {
        items.isEmpty && !removedItems.isEmpty
    }

    /// The right-hand preview, in the current arrangement. The spec id is the page's ORIGINAL
    /// 1-based number — the badge the drop-pages design promises ("labels show each page's
    /// original number"), unique within any arrangement, and a stable SwiftUI identity so a drag
    /// moves cells instead of rebuilding them. The cache key carries the same original index, so
    /// reordering (or restoring a dropped page) is pure cache hits — no re-render.
    private var previewSpecs: [PreviewPageSpec] {
        items.map { item in
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
                emptyTitle: allPagesRemoved ? "All pages removed" : "No PDF selected",
                emptySubtitle: allPagesRemoved
                    ? "Restore a page on the left to preview it."
                    : "Drop a PDF here or choose one to arrange its pages.",
                emptySystemImage: "arrow.up.arrow.down.square",
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
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.reorder.title) failed: \(err.localizedDescription)")
            }
        }
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                headerRow

                Group {
                    if inputURL == nil {
                        emptyDropZone
                    } else {
                        pageListCard
                    }
                }
                .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                    consumeDroppedProviders(providers)
                    return true
                }
            }
            .padding(18)
            .formCard()
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Reorder & save…", busy: busy, canRun: !items.isEmpty) {
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
                    if inputURL != nil, isModified {
                        Button("Reset") { resetOrder() }
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
            return "Drop a PDF or add a file. Drag rows — or use the arrows — to set a new page order, and drop any you don't need."
        }
        return "Drag rows to rearrange, or use ↑ / ↓. Trash a page to leave it out of the saved copy — your original file is untouched."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.square")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Its pages appear as a list you can drag into any order — remove the ones you don't need.")
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

    private var pageListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isGeneratingPreviews && items.isEmpty && removedItems.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading pages…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                if allPagesRemoved {
                    allPagesRemovedNotice
                } else {
                    activePageList
                }
                if !removedItems.isEmpty {
                    removedSection
                }
            }
        }
    }

    private var activePageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(items.count) page\(items.count == 1 ? "" : "s") — drag to reorder")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            List(selection: $selectedItemID) {
                ForEach(items) { item in
                    pageRow(for: item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(rowBackground)
                        .tag(item.id)
                }
                .onMove(perform: moveItems)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220, idealHeight: 320, maxHeight: 460)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
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
                Label("Removed (\(removedItems.count))", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Restore all") { restoreAll() }
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
                ForEach(removedItems) { item in
                    removedRow(for: item)
                }
            }
            // Bound the area so a document with many removed pages can't push the save bar off-screen.
            if removedItems.count > 5 {
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
            ReorderRowThumbnail(cacheKey: "\(fileKeyBase)#\(item.originalIndex)") {
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

            Button { restorePage(item) } label: {
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

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.025))
    }

    private func pageRow(for item: ReorderItem) -> some View {
        let position = items.firstIndex(of: item) ?? 0
        return HStack(alignment: .center, spacing: 12) {
            RowIndexBadge(number: position + 1, accent: accent)

            ReorderRowThumbnail(cacheKey: "\(fileKeyBase)#\(item.originalIndex)") {
                guard let url = inputURL else { return nil }
                return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: item.originalIndex))?.image
            }
            .frame(width: 34, height: 44)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }

            Text("Page \(item.pageNumber)")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button { move(from: position, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(position == 0)
                .help("Move up")

                Button { move(from: position, by: 1) } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(position == items.count - 1)
                .help("Move down")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            }

            Button(role: .destructive) {
                removePage(item)
            } label: {
                Image(systemName: "trash").font(.body.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Remove page \(item.pageNumber) — left out of the saved copy; your file is untouched")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(position + 1), original page \(item.pageNumber)")
    }

    // MARK: - Ordering

    private func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    private func move(from index: Int, by delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    private func resetOrder() {
        // Back to the untouched document: every page present, in original order.
        items = (items + removedItems).sorted { $0.originalIndex < $1.originalIndex }
        removedItems = []
    }

    // MARK: - Removal

    /// Excludes a page from the exported copy. The rendered page is kept in `removedItems` (sorted by
    /// original index) so it can be restored; nothing is written to disk.
    private func removePage(_ item: ReorderItem) {
        guard let index = items.firstIndex(of: item) else { return }
        let removed = items.remove(at: index)
        let insertAt = removedItems.firstIndex { $0.originalIndex > removed.originalIndex } ?? removedItems.count
        removedItems.insert(removed, at: insertAt)
        if selectedItemID == removed.id { selectedItemID = nil }
    }

    /// Puts a removed page back at the end of the working order; the user can drag it wherever they
    /// want from there.
    private func restorePage(_ item: ReorderItem) {
        guard let index = removedItems.firstIndex(of: item) else { return }
        items.append(removedItems.remove(at: index))
    }

    private func restoreAll() {
        guard !removedItems.isEmpty else { return }
        // Append in ascending original order so a bulk restore reads predictably.
        items.append(contentsOf: removedItems.sorted { $0.originalIndex < $1.originalIndex })
        removedItems = []
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            items = []
            removedItems = []
            isGeneratingPreviews = false
            return
        }
        // Clear the old document's rows BEFORE the await: `items` is what "Reorder & save…"
        // applies to the current `inputURL`, so leaving them populated while the new file's
        // thumbnails render lets a click apply document A's page order (and count) to document B —
        // silently truncating it to A's page count. Drop the removed set with it so removals typed
        // against document A can't carry over and silently omit pages from document B.
        items = []
        removedItems = []
        isGeneratingPreviews = true
        do {
            // Only the page count loads up front; row and preview cells render on demand.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            // `.task(id:)` cancelled this load if the user switched files again; a superseded load
            // must neither install its stale rows nor clear the spinner the newer load now owns.
            guard !Task.isCancelled else { return }
            fileKeyBase = PreviewPageSpec.fileKey(for: url)
            items = (0..<count).map { ReorderItem(id: $0) }
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            removedItems = []
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
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    inputURL = url
                    return
                }
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runReorder() async {
        guard let fileURL = inputURL, !items.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.reorder.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.reorder.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-reordered.pdf"
        let order = items.map(\.originalIndex)

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.reorderData(inputURL: fileURL, order: order)
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.reorder.title,
                defaultStem: "reordered",
                suffixWord: "reordered"
            ) {
            case .savedBeside:
                break
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.reorder.title) failed: \(error.localizedDescription)")
        }
    }
}

/// The 34×44 page image in one sidebar row, read from the shared LRU on demand — the same key the
/// preview column uses for that page, so a row and its preview cell share one render. The row holds
/// no image state of its own; a long document's rows stay as cheap as its preview cells.
private struct ReorderRowThumbnail: View {
    let cacheKey: String
    let render: () async -> NSImage?
    /// Repaint trigger after a store; the image itself deliberately lives only in the cache.
    @State private var tick = 0

    var body: some View {
        Group {
            if let image = PreviewThumbnailCache.shared.image(for: cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white
            }
        }
        .id(tick)
        .task(id: cacheKey) {
            guard PreviewThumbnailCache.shared.image(for: cacheKey) == nil else { return }
            guard let rendered = await render(), !Task.isCancelled else { return }
            PreviewThumbnailCache.shared.store(rendered, for: cacheKey)
            tick += 1
        }
    }
}
