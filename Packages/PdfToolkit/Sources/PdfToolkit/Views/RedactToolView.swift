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
    @State private var stripAnnotationsFromOtherPages = false
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "redacted.pdf"
    @State private var isDropTargeted = false

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
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: selectionPathKey) {
            await reloadDocumentForSelection()
        }
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
                canRun: inputURL != nil && pdfDocument != nil && !marks.isEmpty
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
                            inputURL = nil
                            pdfDocument = nil
                            marks = []
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
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            }
            ForEach(marks) { mark in
                HStack {
                    Text("Page \(mark.pageIndex + 1)")
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    Button {
                        marks.removeAll { $0.id == mark.id }
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
                        .fill(Color.primary.opacity(0.03))
                }
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Editor

    private var editorPane: some View {
        Group {
            if let doc = pdfDocument {
                RedactionPDFEditor(document: doc, marks: $marks)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
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

    // MARK: - Data

    private func reloadDocumentForSelection() async {
        marks = []
        pdfDocument = nil
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
            pdfDocument = box.document
            if box.document == nil {
                alertMessage = PDFOperationError.couldNotOpen(url).localizedDescription
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
                    return try PDFExportSupport.data { out in
                        try PDFToolkit.redact(
                            inputURL: fileURL,
                            outputURL: out,
                            marks: marksSnapshot,
                            options: options
                        )
                    }
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
