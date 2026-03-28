import SwiftUI
import UniformTypeIdentifiers

struct CompressToolView: View {
    @State private var inputURL: URL?
    @State private var quality: Double = 0.72
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "compressed.pdf"

    var body: some View {
        ToolFormContainer {
            fileRow
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text(qualityLabel).font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: $quality, in: 0.2...1)
            }
            .padding(16)
            .formCard()

            RunActionButton(title: "Compress & save…", busy: busy) {
                Task { await runCompress() }
            }
        }
        .overlay {
            if busy {
                Color.black.opacity(0.08).ignoresSafeArea()
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                inputURL = urls.first
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: $exportDoc,
            contentType: .pdf,
            defaultFilename: stem(suggestedName)
        ) { result in
            exportDoc = nil
            if case .failure(let err) = result {
                alertMessage = err.localizedDescription
            }
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

    private func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private var qualityLabel: String {
        switch quality {
        case ..<0.45: return "Smaller file"
        case ..<0.75: return "Balanced"
        default: return "Higher quality"
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
    private func runCompress() async {
        guard let inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        defer { busy = false }

        suggestedName = inputURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"

        do {
            let data = try inputURL.withSecurityScopedAccess {
                try PDFExportSupport.data { out in
                    try PDFToolkit.compress(inputURL: inputURL, outputURL: out, quality: quality)
                }
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
