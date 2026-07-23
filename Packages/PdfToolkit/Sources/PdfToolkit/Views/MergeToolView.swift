import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct MergeEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// The pages to take from this file, as an Extract-style range string. Empty = all pages (the
    /// default, and the original whole-file behavior). Honors the order typed (e.g. "5,1,2").
    var rangeText: String = ""
}

private struct MergeResult {
    let outputURL: URL
    let totalPages: Int
    let fileBytes: Int64
}

/// Wraps a per-row range error so the merge alert names the file it came from. A single-file tool's
/// error already reads unambiguously; a multi-file merge needs the filename to point the user at the
/// row to fix.
private struct MergeFileError: LocalizedError {
    let fileName: String
    let underlying: Error
    var errorDescription: String? {
        "\(fileName): \(underlying.localizedDescription)"
    }
}

/// The merged document's pages as they will be written: virtualized preview specs in output order,
/// a lookup from each global page number back to its source (for the render closure and inline
/// page-drop), and the effective total. Derived purely from the queue, page counts, ranges, and
/// drops — no rendering — so a range edit, reorder, or page-drop reshapes it instantly.
private struct MergePreviewLayout {
    var specs: [PreviewPageSpec] = []
    var lookup: [Int: (entryID: UUID, url: URL, pageIndex: Int)] = [:]
    var totalPages: Int { specs.count }
}

struct MergeToolView: View {
    @Environment(\.toolAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var entries: [MergeEntry] = []
    /// The pending "your output will lose X" warning and its acknowledgement.
    @StateObject private var fidelity = OutputFidelityGate()
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var selectedEntryID: UUID?
    @State private var isDropTargeted = false
    @State private var pagesByEntryID: [UUID: Int] = [:]
    /// Entries whose file is password-locked: badged in the list, excluded from the total, and
    /// absent from the preview strip — without this the header counted a locked file's real pages
    /// (locked docs report them) while the strip silently skipped it, and the two contradicted.
    @State private var lockedEntryIDs: Set<UUID> = []
    /// Pages excluded via the inline trash on the combined preview, per file (zero-based indices).
    @State private var droppedByEntryID: [UUID: Set<Int>] = [:]
    @State private var pageSummaryLoading = false

    @State private var thumbnailSize: CGFloat = 120

    @State private var mergeResult: MergeResult?

    private var entriesSignature: String {
        entries.map { "\($0.id.uuidString)|\($0.url.path)" }.joined(separator: "\u{1e}")
    }

    var body: some View {
        Group {
            if let result = mergeResult {
                successView(result)
            } else {
                mergeWorkspace
            }
        }
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                addEntries(urls)
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
        }
        .toolErrorAlert($alertMessage)
        .task(id: entriesSignature) {
            await fidelity.refresh(urls: entries.map(\.url), formLoss: .formOrphaned, checksBookmarks: true)
        }
        .task(id: entriesSignature) {
            await refreshPageSummary()
        }
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { selectedEntryID = nil }
        }
    }

    // HSplitView avoids NavigationSplitView nested inside NavigationStack (broken columns, hidden controls).
    private var mergeWorkspace: some View {
        // Compute the layout once per body pass so the preview strip and its render/drop closures
        // all read the same page→source mapping.
        let layout = previewLayout
        return HSplitView {
            sidebarColumn(effectivePages: layout.totalPages)
                .toolSidebarWidth()
            SinglePDFPreviewColumn(
                pages: layout.specs,
                isGenerating: pageSummaryLoading,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "The pages of the merged file, in order — use the trash on any page to leave it out.",
                // Files queued but nothing previewable means every entry is locked — say that,
                // instead of the "No PDFs selected" copy that would contradict the list.
                emptyTitle: entries.isEmpty ? "No PDFs selected for merge" : "Only password-protected PDFs",
                emptySubtitle: entries.isEmpty
                    ? "Add PDFs in the sidebar or drop PDFs onto the list."
                    : "These files can't be previewed or merged until their passwords are removed (Password Protect → Remove password).",
                emptySystemImage: entries.isEmpty ? "doc.on.doc" : "lock.fill",
                onDeletePage: dropPreviewPage,
                deletePageHelp: "Leave this page out of the merged PDF",
                deletePageAccessibilityLabel: { "Drop page \($0) from the merge" },
                render: { spec in
                    guard let target = layout.lookup[spec.id] else { return nil }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: target.url, pageIndex: target.pageIndex))?.image
                }
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Success

    private func successView(_ result: MergeResult) -> some View {
        ToolSuccessView(
            accent: accent,
            title: "Merged successfully",
            path: result.outputURL.path,
            stats: [
                .init(value: "\(result.totalPages)", label: "pages"),
                .init(value: "\(entries.count)", label: "files"),
                .init(value: formatBytes(result.fileBytes), label: "size"),
            ],
            onShowInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
            },
            onDoAnother: {
                withAnimation {
                    resetAll()
                    mergeResult = nil
                }
            }
        )
    }

    // MARK: - Sidebar

    private func sidebarColumn(effectivePages: Int) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                headerRow

                Group {
                    if entries.isEmpty {
                        emptyMergeDropZone
                    } else {
                        listCard(effectivePages: effectivePages)
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

            VStack(spacing: 10) {
                // A locked file can't be read, so it can't be merged — and merging "the rest" would
                // silently drop a file the user added on purpose. Block the run and say why, rather
                // than fail mid-merge with a bare encryption error, until they remove or unlock it.
                if !lockedEntryIDs.isEmpty {
                    lockedFilesNotice
                }
                // Also disabled while page counts are still loading: resolving a typed range against
                // a not-yet-known count (`pagesByEntryID[...] ?? 0`) would throw a bogus out-of-bounds error.
                if let warning = fidelity.warning {
                    OutputFidelityNote(warning: warning, toolTitle: Tool.merge.title)
                }
                RunActionButton(
                    title: "Merge & save…",
                    busy: busy,
                    canRun: !entries.isEmpty && !pageSummaryLoading && lockedEntryIDs.isEmpty
                ) {
                    guard fidelity.shouldProceed() else { return }
                    Task { await runMerge() }
                }
            }
            .padding(16)
            .toolActionBar()
            .outputFidelityConfirmation(fidelity, toolTitle: Tool.merge.title) {
                Task { await runMerge() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown above the disabled Merge button when the queue holds password-protected files: names how
    /// many and points at the tool that unlocks them, so "why can't I merge?" is answered in place.
    private var lockedFilesNotice: some View {
        let n = lockedEntryIDs.count
        return Label(
            "\(n) file\(n == 1 ? " is" : "s are") password-protected and can't be merged. Remove \(n == 1 ? "it" : "them"), or unlock first with Password Protect → Remove password.",
            systemImage: "lock.trianglebadge.exclamationmark"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Title + actions on one row; subtitle full-width below so buttons never wrap mid-label (e.g. “Clear” / “all”).
    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF files")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !entries.isEmpty {
                        Button("Clear all") {
                            resetAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Remove every file from the list")
                    }
                    Button("Add PDFs…") { showImporter = true }
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

    private var emptyMergeDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop PDFs here or add files")
                .font(.title3.weight(.semibold))
            Text("Files are combined top to bottom. Set page ranges per file; preview updates on the right.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDFs…") { showImporter = true }
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
        .accessibilityLabel("Merge list is empty. Drop PDF files or use choose PDFs.")
    }

    private func listCard(effectivePages: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if rawUnlockedTotal > 0 || !lockedEntryIDs.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(mergeSummaryLine(effectivePages: effectivePages))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if droppedPageCount > 0 {
                        Button("Restore \(droppedPageCount) hidden page\(droppedPageCount == 1 ? "" : "s")") {
                            droppedByEntryID = [:]
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
                        .help("Bring back every page dropped from the preview")
                    }
                }
                .padding(.horizontal, 4)
            }

            List(selection: $selectedEntryID) {
                ForEach($entries) { $entry in
                    mergeRow(entry: $entry)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(rowBackground)
                        .tag(Optional(entry.id))
                }
                .onMove(perform: moveEntries)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 200, idealHeight: 320, maxHeight: 460)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .onDeleteCommand {
            deleteSelectedEntry()
        }
    }

    /// The header total counts only mergeable, still-selected pages; locked entries are called out
    /// separately so the number always matches what the preview strip shows.
    private func mergeSummaryLine(effectivePages: Int) -> String {
        let files = entries.count
        let fileWord = files == 1 ? "file" : "files"
        let raw = rawUnlockedTotal
        let base: String
        if effectivePages == raw {
            base = "\(raw) page\(raw == 1 ? "" : "s") across \(files) \(fileWord)"
        } else {
            base = "\(effectivePages) of \(raw) pages across \(files) \(fileWord)"
        }
        guard !lockedEntryIDs.isEmpty else { return base }
        return base + " — \(lockedEntryIDs.count) password-protected"
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.025))
    }

    private func mergeRow(entry: Binding<MergeEntry>) -> some View {
        let value = entry.wrappedValue
        let index = entries.firstIndex(where: { $0.id == value.id }) ?? 0
        let locked = lockedEntryIDs.contains(value.id)
        return HStack(alignment: .top, spacing: 12) {
            RowIndexBadge(number: index + 1, accent: accent)

            VStack(alignment: .leading, spacing: 6) {
                Text(value.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))

                if locked {
                    // A locked file can't be previewed or merged, so it gets no page range field —
                    // the badge is the whole story until its password is removed.
                    Label("Password-protected — can't merge", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.fieldWarning)
                } else {
                    pageCountLabel(for: value)
                    TextField("e.g. 1, 3-5 · all pages", text: entry.rangeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .accessibilityLabel("Pages to include from \(value.url.lastPathComponent)")
                        .onChange(of: value.rangeText) { _, _ in
                            // A freshly typed range is a new, explicit choice of pages, so it
                            // supersedes this row's earlier inline page-drops. Without this, dropping
                            // page 3 and then typing "3-5" would leave page 3 suppressed (drops apply
                            // after the range in MergePageSelection.resolve) even though the user just
                            // asked to include it.
                            droppedByEntryID[value.id] = nil
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button {
                        moveEntry(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move up")

                    Button {
                        moveEntry(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == entries.count - 1)
                    .help("Move down")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                }

                Button(role: .destructive) {
                    removeEntry(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove from list")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Position \(index + 1), \(value.url.lastPathComponent)")
    }

    /// The "X of N pages" (or plain "N pages") summary for one row, or a warning when its range can't
    /// be parsed — matching how Extract/Split surface bad ranges, but non-blocking while typing.
    @ViewBuilder
    private func pageCountLabel(for entry: MergeEntry) -> some View {
        if let plan = pagePlan(for: entry) {
            if !plan.valid {
                Label("Check the page range", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.fieldWarning)
            } else if plan.indices.count == plan.rawCount {
                Text("\(plan.rawCount) page\(plan.rawCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(plan.indices.count) of \(plan.rawCount) pages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
            }
        } else if pageSummaryLoading {
            Text("Reading pages…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var sidebarSubtitle: String {
        if entries.isEmpty {
            return "Add PDFs — order is top to bottom in the merged file. Set a page range per file, or leave it blank for all pages."
        }
        return "Type pages per file (e.g. 1, 3-5); blank = all. Reorder rows with the arrows; Delete removes the selection."
    }

    // MARK: - Page plans & combined preview

    /// The pages one row contributes, resolved for the live UI (counts, preview) — never throws.
    ///
    /// Returns nil for a locked file or until the file's page count is known. `indices` are the
    /// zero-based pages in output order (empty range = all pages), with inline-dropped pages
    /// removed. `valid` is false when the range text can't be parsed yet; the preview then falls
    /// back to all pages (minus drops) so pages don't blink out mid-type, while the row shows a
    /// "check the range" warning and the actual export re-parses strictly and surfaces the error.
    private func pagePlan(for entry: MergeEntry) -> (indices: [Int], valid: Bool, rawCount: Int)? {
        guard !lockedEntryIDs.contains(entry.id),
              let rawCount = pagesByEntryID[entry.id], rawCount > 0 else { return nil }
        let dropped = droppedByEntryID[entry.id] ?? []
        let trimmed = entry.rangeText.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseIndices: [Int]
        let valid: Bool
        if trimmed.isEmpty {
            baseIndices = Array(0..<rawCount)
            valid = true
        } else if let parsed = try? PageRangeParser.parse(
            trimmed, pageCount: rawCount, emptyMeansAllPages: true, preserveOrder: true
        ) {
            baseIndices = parsed
            valid = true
        } else {
            baseIndices = Array(0..<rawCount)
            valid = false
        }

        return (baseIndices.filter { !dropped.contains($0) }, valid, rawCount)
    }

    /// The preview strip as a pure function of the queue, page counts, ranges, and drops. Global
    /// page numbers run top to bottom across entries; each cell's cache key is content-addressed to
    /// its own file + local page (matching every other grid), so reordering rows, editing a range,
    /// or dropping a page re-maps positions to already-rendered cells instead of re-rendering.
    /// Locked entries have no plan and therefore no cells — the row's lock badge and the header
    /// summary carry the explanation, and the run itself surfaces the hard error.
    private var previewLayout: MergePreviewLayout {
        var layout = MergePreviewLayout()
        var globalPage = 1
        for entry in entries {
            guard let plan = pagePlan(for: entry) else { continue }
            let base = PreviewPageSpec.fileKey(for: entry.url)
            for local in plan.indices {
                layout.specs.append(PreviewPageSpec(id: globalPage, cacheKey: "\(base)#\(local)"))
                layout.lookup[globalPage] = (entry.id, entry.url, local)
                globalPage += 1
            }
        }
        return layout
    }

    /// Raw mergeable pages (locked files excluded), the denominator of the "X of N" summary.
    private var rawUnlockedTotal: Int {
        entries.reduce(0) { $0 + (lockedEntryIDs.contains($1.id) ? 0 : (pagesByEntryID[$1.id] ?? 0)) }
    }

    private var droppedPageCount: Int {
        droppedByEntryID.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Actions

    private func addEntries(_ urls: [URL]) {
        // The same file may be added more than once: the engine merges duplicates faithfully (there
        // is a test for merge([a, a])) and the Help promises "the same file can appear twice if you
        // add it twice." A single picker selection or Finder drag never carries internal duplicates,
        // so appending as-is never silently doubles a file the user chose only once.
        entries.append(contentsOf: urls.map { MergeEntry(url: $0) })
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            addEntries(urls)
        }
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    private func moveEntry(from index: Int, by delta: Int) {
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    private func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries[index].id
        entries.remove(at: index)
        droppedByEntryID[removed] = nil
        if selectedEntryID == removed {
            selectedEntryID = nil
        }
    }

    private func deleteSelectedEntry() {
        guard let id = selectedEntryID, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        removeEntry(at: idx)
    }

    /// Drops one combined-preview page (its 1-based global position) from the merge. Never drops the
    /// last remaining page — the output must keep at least one — so the preview can't be emptied.
    private func dropPreviewPage(atPosition position: Int) {
        let layout = previewLayout
        guard layout.specs.count > 1, let target = layout.lookup[position] else { return }
        droppedByEntryID[target.entryID, default: []].insert(target.pageIndex)
    }

    private func resetAll() {
        entries.removeAll()
        pagesByEntryID = [:]
        lockedEntryIDs = []
        droppedByEntryID = [:]
        selectedEntryID = nil
        pageSummaryLoading = false
    }

    // @MainActor with a synchronous head: the guards and installs before the first await run
    // atomically with task entry, so a superseded pass can no longer resume from a pre-head
    // suspension AFTER the newer pass finished and set the spinner nothing would clear — the last
    // sliver of the cancellation contract the tail guards below already honor.
    @MainActor
    private func refreshPageSummary() async {
        guard !Task.isCancelled else { return }
        let snapshot = entries
        // Drop stale page-drops for files no longer in the list before anything else.
        let liveIDs = Set(snapshot.map(\.id))
        droppedByEntryID = droppedByEntryID.filter { liveIDs.contains($0.key) }
        guard !snapshot.isEmpty else {
            pagesByEntryID = [:]
            lockedEntryIDs = []
            pageSummaryLoading = false
            return
        }
        let urls = snapshot.map(\.url)
        pageSummaryLoading = true
        pagesByEntryID = [:]
        lockedEntryIDs = []
        do {
            let summary: (counts: [UUID: Int], locked: Set<UUID>) = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(urls) {
                    var counts: [UUID: Int] = [:]
                    var locked: Set<UUID> = []
                    for e in snapshot {
                        // One open per file answers both questions. A locked document reports its
                        // real page count, but those pages can't merge or preview — counting them
                        // in the total made the header contradict the strip.
                        guard let doc = PDFDocument(url: e.url) else {
                            counts[e.id] = 0
                            continue
                        }
                        if doc.isLocked {
                            locked.insert(e.id)
                        } else {
                            counts[e.id] = doc.pageCount
                        }
                    }
                    return (counts, locked)
                }
            }
            // The whole function is main-actor now, so the check is atomic with the install with
            // no hop for cancellation to land in: a superseded pass must not put its partial
            // snapshot (a stale total and a prematurely cleared spinner) over the newer pass's.
            guard !Task.isCancelled else { return }
            pagesByEntryID = summary.counts
            lockedEntryIDs = summary.locked
            pageSummaryLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            pagesByEntryID = [:]
            lockedEntryIDs = []
            pageSummaryLoading = false
        }
    }

    @MainActor
    private func runMerge() async {
        guard !entries.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }
        // The run button is disabled while counts load, but guard here too: resolving a typed range
        // against an unknown page count would surface a false "page N is not in this document".
        guard !pageSummaryLoading else { return }

        // Resolve every row's pages up front so an unparseable range (or a page outside the file) is
        // reported the same way Extract/Split do — before the user is asked to pick a destination.
        let plans: [(url: URL, pageIndices: [Int]?)]
        do {
            plans = try makeMergePlans()
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.merge.title) failed: \(error.localizedDescription)")
            return
        }

        let firstURL = entries.first?.url
        let stem = firstURL?.deletingPathExtension().lastPathComponent ?? "merged"
        let filename = PDFExportCoordinator.suggestedFilename(stem: stem, suffixWord: "merged")

        let outputURL: URL
        if SaveLocation.current() == .besideOriginal, let firstURL {
            // Write next to the first input, numbering rather than overwriting on a clash.
            outputURL = PDFExportCoordinator.uniqueURL(inDirectory: firstURL.deletingLastPathComponent(), filename: filename)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            outputURL = url
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.merge.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.merge.title)
        }

        let urlsSnapshot = plans.map(\.url)
        let stripMetadata = UserDefaults.standard.bool(forKey: SettingsKeys.stripMetadataOnExport)

        do {
            // Refuse to write over one of the inputs. The single-file tools get this from
            // `PDFToolkit.merge(...)`, but this path calls `mergeData` and writes itself (to honor
            // strip-metadata and read back the page count), so it must apply the same guard — else
            // a Save-panel destination that names an input silently overwrites that original.
            try PDFToolkit.requireDistinctOutput(outputURL, from: urlsSnapshot)
            // Materialize the merged bytes in memory, then land them atomically: writing the
            // PDFDocument straight onto the destination would truncate an existing file before the
            // merge finished serializing, so a mid-write failure (full disk, crash) destroys
            // whatever the user chose to replace. Every single-file tool already works this way.
            try await PDFBackgroundWork.run {
                let merged = try URLCollectionSecurityScope.withAccess(urlsSnapshot) {
                    try PDFToolkit.mergeData(inputs: plans)
                }
                // Honor the Files-tab "Strip metadata on export" setting, exactly like the
                // single-file tools do via PDFExportCoordinator.route.
                let finalized = stripMetadata ? PDFExportCoordinator.stripMetadata(merged) : merged
                try finalized.write(to: outputURL, options: .atomic)
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let bytes = attrs[.size] as? Int64 ?? 0

            let finalPages = try await PDFBackgroundWork.run {
                PDFToolkit.pageCount(at: outputURL) ?? 0
            }

            withAnimation {
                mergeResult = MergeResult(outputURL: outputURL, totalPages: finalPages, fileBytes: bytes)
            }
            ActivityLog.shared.recordSaved(Tool.merge.title, to: outputURL, bytes: Int(bytes), detail: "\(urlsSnapshot.count) files")
            AfterExportAction.current().perform(on: [outputURL])
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.merge.title) failed: \(error.localizedDescription)")
        }
    }

    /// Turns each row into a merge input via ``MergePageSelection/resolve(rangeText:dropped:pageCount:)``
    /// — blank-and-undropped rows stay `nil` (whole file), the rest resolve to their chosen pages in
    /// typed order minus any inline-dropped pages. Throws the same errors Extract raises on a bad
    /// range so the run surfaces them identically. A locked file resolves to `nil` here and fails at
    /// merge time with the actionable encryptedInput error, exactly as before.
    private func makeMergePlans() throws -> [(url: URL, pageIndices: [Int]?)] {
        try entries.map { entry in
            do {
                let indices = try MergePageSelection.resolve(
                    rangeText: entry.rangeText,
                    dropped: droppedByEntryID[entry.id] ?? [],
                    pageCount: pagesByEntryID[entry.id] ?? 0
                )
                return (entry.url, indices)
            } catch {
                // Name the offending file: a bare "Invalid page range: …" in a multi-file merge
                // doesn't tell the user which row to fix.
                throw MergeFileError(fileName: entry.url.lastPathComponent, underlying: error)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
