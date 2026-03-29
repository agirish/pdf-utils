import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct RedactToolView: View {
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
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
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
            exportDoc = nil
            if case .failure(let err) = result { alertMessage = err.localizedDescription }
        }
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: selectionPathKey) { _, _ in
            reloadDocumentForSelection()
        }
        .onAppear(perform: reloadDocumentForSelection)
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
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: Tool.redact.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.redact.accent)
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
                    Button("Choose PDF…") { showImporter = true }
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
                .foregroundStyle(Tool.redact.accent.opacity(0.85))
            Text("Drop a PDF here")
                .font(.title3.weight(.semibold))
            Text("Redaction is offline on your Mac—nothing is uploaded.")
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
                .foregroundStyle(isDropTargeted ? Tool.redact.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.redact.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.redact.accent)
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
                    Text("Loading…")
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
                "Marked areas are rasterized with solid black pixels—the original text and vectors there are not recoverable from the exported PDF. Processing never leaves your Mac."
            )
            .font(.caption)
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
                .foregroundStyle(Tool.redact.accent)
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
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder.rectangular")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Preview")
                        .font(.title3.weight(.semibold))
                    Text("Choose a file to mark sensitive areas with ⇧ Shift-drag.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    // MARK: - Data

    private func reloadDocumentForSelection() {
        marks = []
        guard let url = inputURL else {
            pdfDocument = nil
            return
        }
        do {
            try url.withSecurityScopedAccess {
                pdfDocument = PDFDocument(url: url)
            }
            if pdfDocument == nil {
                alertMessage = PDFOperationError.couldNotOpen(url).localizedDescription
            }
        } catch {
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
            maxPixelDimension: 2400
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
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
