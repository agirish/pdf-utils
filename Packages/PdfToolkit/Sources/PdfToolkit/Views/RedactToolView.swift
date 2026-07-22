import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct RedactToolView: View {
    @Environment(\.toolAccent) private var accent
    @AppStorage(SettingsKeys.redactRasterLongEdge)
    private var rasterLongEdge: Double = 4000

    @State private var inputURL: URL?
    @State private var pdfDocument: PDFDocument?
    @State private var marks: [RedactionMark] = []
    /// The region selected for editing — shared with the canvas so a click there and a tap in the
    /// Regions list agree, and so the corner handle and keyboard edits know what to act on.
    @State private var selectedMarkID: UUID?
    /// ⌘Z / ⌘⇧Z history over the whole marks set. Driven from `.onChange(of: marks)`, so every way the
    /// set changes — draw, move, resize, nudge, delete, Find & redact, Clear — is one coherent undo.
    @State private var undo = UndoHistory<[RedactionMark]>([])
    /// True while a canvas drag is in flight, so the whole drag collapses into a single undo step.
    @State private var canvasInteracting = false
    @State private var stripAnnotationsFromOtherPages = false
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "redacted.pdf"
    @State private var isDropTargeted = false

    // MARK: Find & redact
    @State private var searchText = ""
    @State private var searching = false
    /// The in-flight scan, so Cancel and leaving the screen can abort it — a text sweep holds the
    /// shared PDF serial queue the same way OCR does.
    @State private var searchTask: Task<Void, Never>?
    @State private var searchProgressPage = 0
    @State private var searchProgressTotal = 0
    /// Bumped at every scan start and end; progress hops to the main actor out of order, so the
    /// generation check drops stragglers from a finished scan (OCR's pattern).
    @State private var searchGeneration = 0
    @State private var lastFindSummary: FindSummary?

    /// A finished scan's numbers, for the "N matches on M pages" line.
    private struct FindSummary {
        let target: String
        let matchCount: Int
        let pageCount: Int
        /// Marks actually added after de-duping against ones already present.
        let addedCount: Int
        let pagesWithoutText: Int
    }

    private var autoMarkCount: Int {
        marks.reduce(0) { $0 + ($1.origin == .autoMatch ? 1 : 0) }
    }

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth(.compact)
            editorPane
                .frame(minWidth: 480)
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.redact.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.redact.title) failed: \(err.localizedDescription)")
            }
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await reloadDocumentForSelection()
        }
        // Record every settled change to the marks as one undo step — but not the intermediate frames
        // of a live drag (canvasInteracting gates those; the drag's final value is committed when the
        // interaction flag flips false, below). A commit equal to the current snapshot is a no-op, so
        // the re-commit that fires when undo/redo reassigns `marks` records nothing.
        .onChange(of: marks) { _, newMarks in
            if !canvasInteracting { undo.commit(newMarks) }
        }
        .onChange(of: canvasInteracting) { _, interacting in
            if !interacting { undo.commit(marks) }
        }
        // Leaving the screen must free the PDF serial queue rather than let a scan finish unseen.
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func performUndo() {
        guard let restored = undo.undo() else { return }
        marks = restored
        if let sel = selectedMarkID, !marks.contains(where: { $0.id == sel }) { selectedMarkID = nil }
    }

    private func performRedo() {
        guard let restored = undo.redo() else { return }
        marks = restored
        if let sel = selectedMarkID, !marks.contains(where: { $0.id == sel }) { selectedMarkID = nil }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow

                    Group {
                        if inputURL == nil {
                            emptyDropZone
                        } else if let url = inputURL {
                            selectedFileCard(url: url)
                        }
                    }
                    .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                        consumeDroppedProviders(providers)
                        return true
                    }

                    if pdfDocument != nil {
                        findRedactSection
                    }

                    securitySection

                    if !marks.isEmpty {
                        marksSection
                    }
                }
                .padding(18)
                .formCard()
                .padding(12)
            }

            Divider()

            RunActionButton(
                title: "Redact & save…",
                busy: busy,
                canRun: inputURL != nil && pdfDocument != nil && !marks.isEmpty && !searching
            ) {
                Task { await runRedact() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: Tool.redact.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") {
                            searchTask?.cancel()
                            inputURL = nil
                            pdfDocument = nil
                            marks = []
                            selectedMarkID = nil
                            undo.reset([])
                            resetFindState()
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                }
            }
            Text(sidebarSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Add a PDF, then hold ⇧ Shift and drag on the preview to draw black-out regions."
        }
        return "⇧ Shift-drag on pages to mark what to remove permanently. Export writes a new file; your original stays unchanged until you overwrite it."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: Tool.redact.symbolName)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Redaction is offline on your Mac — nothing is uploaded.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
        .accessibilityLabel("No file selected. Drop a PDF or add a file.")
    }

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
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if let doc = pdfDocument {
                    Text("\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s") · \(marks.count) redaction region\(marks.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
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
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security")
                .font(.subheadline.weight(.semibold))
            Text(
                "Every page you mark is rebuilt as an image with solid black over each region — the text and vectors under the marks can't be recovered, and the rest of that page becomes non-selectable. Pages you don't mark are left untouched. Processing never leaves your Mac."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Remove highlights & notes from other pages", isOn: $stripAnnotationsFromOtherPages)
                .font(.subheadline)
            Text(
                "When enabled, annotations on pages you did not redact are stripped so hidden comments cannot leak in the copy."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Redacted page sharpness")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Higher values rasterize redacted pages with more pixels so remaining text stays crisp. Unredacted pages are unchanged."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("2400")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Slider(value: $rasterLongEdge, in: 2400...7200, step: 200)
                    Text("7200")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text("\(Int(rasterLongEdge)) px on longest edge")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        }
        .padding(16)
        .formCard()
    }

    private var marksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Regions (\(marks.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear all") {
                    marks = []
                    selectedMarkID = nil
                    lastFindSummary = nil
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            }
            Text("Click a region here or on the page to select it, then drag it to move or drag its corner handle to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if autoMarkCount > 0 {
                HStack {
                    Text("\(autoMarkCount) from Find & redact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear auto-marks") {
                        marks.removeAll { $0.origin == .autoMatch }
                        if let sel = selectedMarkID, !marks.contains(where: { $0.id == sel }) {
                            selectedMarkID = nil
                        }
                        lastFindSummary = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
                }
            }
            ForEach(marks) { mark in
                let isSelected = mark.id == selectedMarkID
                HStack(spacing: 8) {
                    Text("Page \(mark.pageIndex + 1)")
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    if mark.origin == .autoMatch {
                        Text("Auto")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(accent.opacity(0.14)))
                            .foregroundStyle(accent)
                            .accessibilityLabel("Auto-detected match")
                    }
                    Button {
                        marks.removeAll { $0.id == mark.id }
                        if selectedMarkID == mark.id { selectedMarkID = nil }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this region")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.03))
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Toggle: tapping the selected row again clears the selection.
                    selectedMarkID = (selectedMarkID == mark.id) ? nil : mark.id
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel("Region on page \(mark.pageIndex + 1)")
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Find & redact

    private var findRedactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find & redact")
                .font(.subheadline.weight(.semibold))
            Text("Search the text, and every match is added as a redaction region you can review, adjust, or delete. Nothing is removed until you export.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Find text — e.g. an email or name", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitLiteralSearch)
                    .disabled(searching || busy)
                Button(action: submitLiteralSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedSearch.isEmpty || searching || busy)
                .help("Mark every occurrence of this text")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Patterns")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 116), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(FindRedactPattern.allCases) { pattern in
                        presetChip(pattern)
                    }
                }
            }

            if searching {
                findProgressView
            } else if let summary = lastFindSummary {
                findSummaryView(summary)
            }
        }
        .padding(16)
        .formCard()
    }

    private func presetChip(_ pattern: FindRedactPattern) -> some View {
        Button {
            runFindTask(.pattern(pattern))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pattern.symbolName)
                    .font(.caption)
                Text(pattern.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.28), lineWidth: 1)
            }
            .foregroundStyle(accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching || busy)
        .help("Mark every \(pattern.displayName.lowercased()) match")
    }

    private var findProgressView: some View {
        VStack(spacing: 6) {
            if searchProgressTotal > 0 {
                ProgressView(value: Double(searchProgressPage), total: Double(searchProgressTotal))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text(searchProgressTotal > 0
                     ? "Scanning page \(searchProgressPage) of \(searchProgressTotal)…"
                     : "Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel") { searchTask?.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func findSummaryView(_ summary: FindSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.matchCount == 0 {
                Label("No matches for \(summary.target).", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(matchSummaryText(summary), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.pagesWithoutText > 0 {
                Label(
                    "\(summary.pagesWithoutText) page\(summary.pagesWithoutText == 1 ? "" : "s") have no searchable text — a scan search can't read. Mark those by hand.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func matchSummaryText(_ summary: FindSummary) -> String {
        let matchPart = "\(summary.matchCount) match\(summary.matchCount == 1 ? "" : "es")"
        let pagePart = "\(summary.pageCount) page\(summary.pageCount == 1 ? "" : "s")"
        var text = "\(matchPart) for \(summary.target) on \(pagePart)."
        if summary.addedCount == 0 {
            text += " Already marked."
        } else if summary.addedCount < summary.matchCount {
            text += " \(summary.addedCount) new."
        }
        return text
    }

    // MARK: - Editor

    private var editorPane: some View {
        Group {
            if let doc = pdfDocument {
                VStack(spacing: 0) {
                    editorToolbar
                    Divider().opacity(0.35)
                    RedactionPDFEditor(
                        document: doc,
                        marks: $marks,
                        selectedID: $selectedMarkID,
                        isInteracting: $canvasInteracting,
                        onUndo: performUndo,
                        onRedo: performRedo
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            } else if inputURL != nil {
                ProgressView("Opening PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                EmptyStateView(
                    icon: "viewfinder.rectangular",
                    title: "No PDF selected",
                    message: "Choose a file to mark sensitive areas with ⇧ Shift-drag."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    /// A thin bar above the canvas: Undo/Redo (mouse path for the same history ⌘Z reaches) plus a
    /// one-line reminder of the direct-manipulation gestures.
    private var editorToolbar: some View {
        HStack(spacing: 10) {
            EditorUndoButtons(canUndo: undo.canUndo, canRedo: undo.canRedo, accent: accent, undo: performUndo, redo: performRedo)
            Spacer(minLength: 8)
            Text("⇧-drag to draw · drag to move · handle to resize · arrows to nudge · ⌘Z to undo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Data

    private func reloadDocumentForSelection() async {
        searchTask?.cancel()
        marks = []
        selectedMarkID = nil
        undo.reset([])
        pdfDocument = nil
        resetFindState()
        guard let url = inputURL else { return }
        do {
            // Load off the main thread AND on the shared PDFKit serial queue: constructing
            // PDFDocument(url:) here directly beachballed the UI on slow volumes (the
            // "Opening PDF…" state could never render) and ran PDFKit concurrently with
            // queue-side work — the exact access pattern the serialization invariant forbids.
            let box = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess { PDFDocumentBox(document: PDFDocument(url: url)) }
            }
            guard !Task.isCancelled else { return }
            if box.document == nil {
                alertMessage = PDFOperationError.couldNotOpen(url).localizedDescription
            } else if box.document?.isLocked == true {
                // A locked document loads "fine" but every page is a blank placeholder — the user
                // would mark redactions on empty pages and only learn why at export. Refuse at
                // load with the same message the export guard uses, and CLEAR the selection:
                // leaving inputURL set stranded the pane on "Opening PDF…" forever after the
                // alert, and made re-selecting the same file (once unlocked) a no-op because the
                // task id never changed. Clean Metadata's refusal established this pattern.
                alertMessage = PDFOperationError.encryptedInput(url).localizedDescription
                inputURL = nil
            } else {
                pdfDocument = box.document
            }
        } catch is CancellationError {
            // Superseded by another document switch; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pdfDocument = nil
            alertMessage = error.localizedDescription
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

    // MARK: - Find & redact logic

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitLiteralSearch() {
        let needle = trimmedSearch
        guard !needle.isEmpty else { return }
        runFindTask(.literal(needle))
    }

    private func runFindTask(_ query: FindRedactQuery) {
        guard inputURL != nil, !searching, !busy else { return }
        searchTask = Task { await runFind(query) }
    }

    private func resetFindState() {
        searchText = ""
        lastFindSummary = nil
        searchProgressPage = 0
        searchProgressTotal = 0
    }

    /// Runs one scan on the serial queue and folds the found regions into `marks` as reviewable
    /// auto-marks. It never applies anything — redaction still waits for the explicit Redact & save.
    @MainActor
    private func runFind(_ query: FindRedactQuery) async {
        guard let fileURL = inputURL else { return }

        searching = true
        searchProgressPage = 0
        searchProgressTotal = 0
        searchGeneration += 1
        let generation = searchGeneration
        defer {
            searching = false
            searchProgressTotal = 0
            // Invalidate stragglers still queued on the main actor from this scan.
            searchGeneration += 1
            searchTask = nil
        }

        do {
            let result = try await PDFBackgroundWork.run { isCancelled in
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.findRedactionMarks(
                        inputURL: fileURL,
                        query: query,
                        progress: { page, total in
                            Task { @MainActor in
                                guard generation == searchGeneration, page > searchProgressPage else { return }
                                searchProgressPage = page
                                searchProgressTotal = total
                            }
                        },
                        isCancelled: isCancelled
                    )
                }
            }

            let added = appendAutoMarks(result.marks())
            lastFindSummary = FindSummary(
                target: query.describedTarget,
                matchCount: result.matchCount,
                pageCount: result.pageCount,
                addedCount: added,
                pagesWithoutText: result.pagesWithoutText.count
            )
            ActivityLog.shared.info(
                "\(Tool.redact.title): found \(result.matchCount) match\(result.matchCount == 1 ? "" : "es") for \(query.describedTarget); \(added) region\(added == 1 ? "" : "s") marked for review."
            )
        } catch is CancellationError {
            // Cancelled deliberately (Cancel button or leaving the screen); nothing to report.
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.redact.title) search failed: \(error.localizedDescription)")
        }
    }

    /// Appends new auto-marks, skipping any that duplicate a region already present (same page, same
    /// rectangle within half a point) so re-running a search doesn't stack identical boxes. Returns
    /// how many were actually added.
    private func appendAutoMarks(_ newMarks: [RedactionMark]) -> Int {
        var added = 0
        for mark in newMarks {
            let duplicate = marks.contains { existing in
                existing.pageIndex == mark.pageIndex && Self.rectsNearlyEqual(existing.rect, mark.rect)
            }
            guard !duplicate else { continue }
            marks.append(mark)
            added += 1
        }
        return added
    }

    private static func rectsNearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 0.5
        return abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
            && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    @MainActor
    private func runRedact() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }
        guard !marks.isEmpty else {
            alertMessage = PDFOperationError.noRedactions.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.redact.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.redact.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-redacted.pdf"
        let marksSnapshot = marks
        let strip = stripAnnotationsFromOtherPages
        let options = PDFRedactionExportOptions(
            stripAnnotationsFromUnredactedPages: strip,
            maxPixelDimension: CGFloat(min(max(rasterLongEdge, 2400), 7200))
        )

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.redactData(
                        inputURL: fileURL,
                        marks: marksSnapshot,
                        options: options
                    )
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.redact.title,
                defaultStem: "redacted",
                suffixWord: "redacted"
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
            ActivityLog.shared.error("\(Tool.redact.title) failed: \(error.localizedDescription)")
        }
    }
}
