import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Which lever drives the crop: automatic content detection, hand-typed margins, or a rectangle
/// dragged directly on the page.
private enum CropMode: Hashable {
    case auto
    case custom
    case drag
}

struct CropToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    @State private var mode: CropMode = .auto
    @State private var padding: Double = 12
    /// Auto-detect only: unify the detected trim into one uniform crop across all pages.
    @State private var unified = true
    /// Drag-to-crop only: apply the dragged box to every page, or just the page being viewed. Kept
    /// separate from `unified` so switching modes never carries one lever's meaning into the other.
    @State private var dragAllPages = true
    @State private var topInset: Double = 0
    @State private var leftInset: Double = 0
    @State private var bottomInset: Double = 0
    @State private var rightInset: Double = 0
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "cropped.pdf"
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    // Drag-to-crop: a full document loaded on demand (only this mode needs an interactive PDFView),
    // the page the marquee is drawn on, and the fit-to-view zoom.
    @State private var pdfDocument: PDFDocument?
    @State private var dragPageIndex = 0
    @State private var dragZoom: CGFloat = 1

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var customInsets: CropInsets {
        CropInsets(top: topInset, left: leftInset, bottom: bottomInset, right: rightInset)
    }

    private var canRun: Bool {
        guard inputURL != nil else { return false }
        return mode == .auto || !customInsets.isZero
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            previewColumn
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.crop.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.crop.title) failed: \(err.localizedDescription)")
            }
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
        .onChange(of: mode) { _, newMode in
            // The interactive PDFView is drag-only; drop the loaded document when leaving so a big
            // file isn't pinned in memory while Auto/Custom use the virtualized thumbnail grid.
            if newMode != .drag { pdfDocument = nil }
        }
    }

    // MARK: - Preview column

    @ViewBuilder
    private var previewColumn: some View {
        if mode == .drag {
            marqueePane
        } else {
            SinglePDFPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Pages before cropping. The trim applies to every page when you save.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to trim its margins.",
                emptySystemImage: "crop",
                render: { spec in
                    guard let url = inputURL else { return nil }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: spec.id - 1))?.image
                }
            )
        }
    }

    /// Drag-to-crop's right column: an interactive single-page editor loaded on demand. The load lives
    /// here, so it runs only while this pane is on screen (this mode), and re-runs when the file changes.
    private var marqueePane: some View {
        Group {
            if inputURL == nil {
                EmptyStateView(
                    icon: "crop",
                    title: "No PDF selected",
                    message: "Drop a PDF here or choose one, then drag a box to crop it."
                )
            } else if let doc = pdfDocument {
                marqueeEditor(doc: doc)
            } else {
                ProgressView("Opening PDF…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToolPreviewPaneBackground())
        .task(id: selectionPathKey) { await loadInteractiveDoc() }
    }

    private func marqueeEditor(doc: PDFDocument) -> some View {
        let pageCount = max(1, doc.pageCount)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("Drag to crop")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    if pageCount > 1 { pageNavigator(pageCount: pageCount) }
                }
                Text("Drag a box on the page, or pull the handles. The dimmed area is trimmed away.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)

            Divider().opacity(0.35)

            CropMarqueePDFEditor(
                document: doc,
                pageIndex: min(dragPageIndex, pageCount - 1),
                insets: Binding(get: { customInsets }, set: { setInsets($0) }),
                zoom: dragZoom,
                accent: accent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider().opacity(0.35)

            zoomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pageNavigator(pageCount: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                dragPageIndex = max(0, min(dragPageIndex, pageCount - 1) - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(dragPageIndex <= 0)
            .help("Previous page")

            Text("Page \(min(dragPageIndex, pageCount - 1) + 1) of \(pageCount)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            Button {
                dragPageIndex = min(pageCount - 1, min(dragPageIndex, pageCount - 1) + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(dragPageIndex >= pageCount - 1)
            .help("Next page")
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $dragZoom, in: 1...4)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("\(Int((dragZoom * 100).rounded()))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zoom, \(Int((dragZoom * 100).rounded())) percent")
    }

    private func setInsets(_ i: CropInsets) {
        topInset = i.top
        leftInset = i.left
        bottomInset = i.bottom
        rightInset = i.right
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                    }
                    .padding(18)
                    .formCard()

                    if inputURL != nil {
                        cropSection
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Crop & save…", busy: busy, canRun: canRun) {
                Task { await runCrop() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "crop")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") {
                            inputURL = nil
                        }
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
            Text(inputURL == nil
                 ? "Drop a PDF or add a file, then choose how to trim it."
                 : "Auto-detect finds the content on each page; custom margins trim fixed amounts; drag to crop draws the box right on the page.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "crop")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Trim wasteful margins from scans and handouts—the content itself is never deleted.")
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
                if isGeneratingPreviews {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else if !pageSpecs.isEmpty {
                    Text("\(pageSpecs.count) page\(pageSpecs.count == 1 ? "" : "s")")
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

    // MARK: - Crop controls

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Crop mode", selection: $mode) {
                Text("Auto-detect").tag(CropMode.auto)
                Text("Custom margins").tag(CropMode.custom)
                Text("Drag to crop").tag(CropMode.drag)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .auto:
                autoControls
            case .custom:
                customControls
            case .drag:
                dragControls
            }
        }
        .padding(16)
        .formCard()
    }

    private var autoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Breathing room")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TextField("12", value: $padding, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Text("pt")
                    .foregroundStyle(.secondary)
                Stepper("Breathing room", value: $padding, in: 0...144, step: 4)
                    .labelsHidden()
            }
            Toggle("Use the same crop on every page", isOn: $unified)
                .toggleStyle(.checkbox)
                .font(.subheadline)
            Text(unified
                 ? "Finds the content on each page, then applies the smallest safe trim uniformly—a steady frame for book scans."
                 : "Each page is trimmed to its own content. Pages can end up different sizes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Top/Bottom/Left/Right point fields, shared by Custom margins and Drag to crop — both edit
    /// the same four insets, so the grid lives in one place.
    private var edgeInsetGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                insetField("Top", value: $topInset)
                insetField("Bottom", value: $bottomInset)
            }
            GridRow {
                insetField("Left", value: $leftInset)
                insetField("Right", value: $rightInset)
            }
        }
    }

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim from each edge")
                .font(.subheadline.weight(.semibold))
            edgeInsetGrid
            Text("Amounts are in points (72 pt = 1 inch, 28 pt ≈ 1 cm), measured on the page as displayed. The same trim applies to every page.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dragControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim from each edge")
                .font(.subheadline.weight(.semibold))
            edgeInsetGrid
            Toggle("Use the same crop on every page", isOn: $dragAllPages)
                .toggleStyle(.checkbox)
                .font(.subheadline)
            Text(dragAllPages
                 ? "Drag the box on the page at right; the same trim applies to every page. The fields track the box—type to nudge it to the point."
                 : "Only the page you’re viewing is cropped to the box. Every other page is left exactly as it is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset selection") { setInsets(CropInsets()) }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .disabled(customInsets.isZero)
                .help("Clear the crop back to the full page")
        }
    }

    private func insetField(_ label: String, value: Binding<Double>) -> some View {
        // A margin is a trim inward, so it can't be negative — a negative value flips the sign in
        // `insetRect` and *grows* the crop box past the page. Clamp on commit so the field can only
        // hold a non-negative trim; over-trimming is still caught later by cropData's cropTooSmall guard.
        let nonNegative = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max(0, $0) }
        )
        return HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .frame(width: 52, alignment: .leading)
            TextField("0", value: nonNegative, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            Text("pt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            pageSpecs = []
            isGeneratingPreviews = false
            return
        }
        pageSpecs = []
        isGeneratingPreviews = true
        do {
            // Only the page count loads up front; cells render on demand as they appear.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            guard !Task.isCancelled else { return }
            pageSpecs = PreviewPageSpec.specs(forPDFAt: url, pageCount: count)
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pageSpecs = []
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

    /// Loads the full document the marquee editor needs, off the main thread and on the shared PDFKit
    /// serial queue (the same pattern Redact uses). Resets first, so a file switch never shows the
    /// previous document. A locked/corrupt file is left for the thumbnail loader and the save path to
    /// report — this pane just stays on its "Opening…"/empty state rather than double-alerting.
    private func loadInteractiveDoc() async {
        pdfDocument = nil
        dragPageIndex = 0
        guard let url = inputURL else { return }
        do {
            let box = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess { PDFDocumentBox(document: PDFDocument(url: url)) }
            }
            guard !Task.isCancelled else { return }
            if let doc = box.document, doc.isLocked == false, doc.pageCount > 0 {
                pdfDocument = doc
            }
        } catch is CancellationError {
            // Superseded by another selection; the newer load owns the state.
        } catch {
            // Non-fatal here; surfaced elsewhere.
        }
    }

    // MARK: - Export

    @MainActor
    private func runCrop() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.crop.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.crop.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-cropped.pdf"
        let selectedMode = mode
        let insetsSnapshot = customInsets
        let paddingSnapshot = CGFloat(max(0, padding))
        let unifiedSnapshot = unified
        let dragAllPagesSnapshot = dragAllPages
        // For "this page only" in drag mode, clamp the viewed page to the document's real range.
        let dragPageSnapshot = min(max(dragPageIndex, 0), max(0, (pdfDocument?.pageCount ?? 1) - 1))

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    switch selectedMode {
                    case .auto:
                        return try PDFToolkit.autoCropData(
                            inputURL: fileURL,
                            padding: paddingSnapshot,
                            unified: unifiedSnapshot
                        )
                    case .custom:
                        return try PDFToolkit.cropData(inputURL: fileURL, insets: insetsSnapshot)
                    case .drag:
                        let indices: Set<Int>? = dragAllPagesSnapshot ? nil : [dragPageSnapshot]
                        return try PDFToolkit.cropData(inputURL: fileURL, insets: insetsSnapshot, pageIndices: indices)
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.crop.title,
                defaultStem: "cropped",
                suffixWord: "cropped"
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
            ActivityLog.shared.error("\(Tool.crop.title) failed: \(error.localizedDescription)")
        }
    }
}
