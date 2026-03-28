import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct DeletePagesToolView: View {
    @State private var inputURL: URL?
    @State private var rangeText = ""
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "edited.pdf"

    var body: some View {
        ToolFormContainer {
            fileRow

            VStack(alignment: .leading, spacing: 8) {
                Text("Pages to remove").font(.subheadline.weight(.semibold))
                Text("Example: 1, 3-5 removes those pages from a copy of the PDF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. 2, 4-6", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .formCard()

            RunActionButton(title: "Delete pages & save…", busy: busy) {
                Task { await runDelete() }
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
    private func runDelete() async {
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

        suggestedName = inputURL.deletingPathExtension().lastPathComponent + "-edited.pdf"

        do {
            let data = try PDFExportSupport.data { out in
                try PDFToolkit.deletePages(inputURL: inputURL, outputURL: out, pageIndices: indices)
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
