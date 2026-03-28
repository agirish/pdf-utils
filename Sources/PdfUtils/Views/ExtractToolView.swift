import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtractToolView: View {
    @State private var inputURL: URL?
    @State private var rangeText = "1"
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "extracted.pdf"

    var body: some View {
        ToolFormContainer {
            fileRow

            VStack(alignment: .leading, spacing: 8) {
                Text("Pages to extract").font(.subheadline.weight(.semibold))
                Text("Use page numbers like 1, 3-5, 8. Leave empty for all pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. 1, 3-5", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .formCard()

            RunActionButton(title: "Extract & save…", busy: busy) {
                Task { await runExtract() }
            }
        }
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) {
            result in
            switch result {
            case .success(let urls): inputURL = urls.first
            case .failure(let err): alertMessage = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: $exportDoc,
            contentType: .pdf,
            defaultFilename: (suggestedName as NSString).deletingPathExtension
        ) { result in
            exportDoc = nil
            if case .failure(let err) = result { alertMessage = err.localizedDescription }
        }
        .alert("pdf-utils", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var fileRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("PDF file").font(.subheadline.weight(.semibold))
                Text(inputURL?.lastPathComponent ?? "None selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { showImporter = true }
        }
        .padding(16)
        .formCard()
    }

    @MainActor
    private func runExtract() async {
        guard let inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        let access = inputURL.startAccessingSecurityScopedResource()
        defer { if access { inputURL.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: inputURL) else {
            alertMessage = PDFOperationError.couldNotOpen(inputURL).localizedDescription
            return
        }

        let count = doc.pageCount
        guard count > 0 else {
            alertMessage = "This PDF has no pages."
            return
        }

        let indices: [Int]
        do {
            indices = try PageRangeParser.parse(rangeText, pageCount: count)
        } catch {
            alertMessage = error.localizedDescription
            return
        }

        busy = true
        defer { busy = false }

        suggestedName = inputURL.deletingPathExtension().lastPathComponent + "-extracted.pdf"

        do {
            let data = try PDFExportSupport.data { out in
                try PDFToolkit.extract(inputURL: inputURL, outputURL: out, pageIndices: indices)
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
