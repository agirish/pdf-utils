import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct RotateToolView: View {
    @State private var inputURL: URL?
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var quarterTurns = 1
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "rotated.pdf"

    enum PageScope: String, CaseIterable, Identifiable {
        case all
        case range
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All pages"
            case .range: return "Page range"
            }
        }
    }

    var body: some View {
        ToolFormContainer {
            fileRow

            VStack(alignment: .leading, spacing: 12) {
                Text("Pages").font(.subheadline.weight(.semibold))
                Picker("Scope", selection: $scope) {
                    ForEach(PageScope.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                if scope == .range {
                    TextField("e.g. 1, 3-5, 8", text: $rangeText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(16)
            .formCard()

            VStack(alignment: .leading, spacing: 12) {
                Text("Rotation").font(.subheadline.weight(.semibold))
                Picker("Turns", selection: $quarterTurns) {
                    Text("90° clockwise").tag(1)
                    Text("180°").tag(2)
                    Text("270° clockwise").tag(3)
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .formCard()

            RunActionButton(title: "Rotate & save…", busy: busy) {
                Task { await runRotate() }
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
            document: exportDoc,
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
    private func runRotate() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation("Rotate Pages")
        defer {
            busy = false
            AppStateManager.shared.endOperation("Rotate Pages")
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-rotated.pdf"
        let scopeSnapshot = scope
        let rangeSnapshot = rangeText
        let quarterTurnsSnapshot = quarterTurns

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    guard let doc = PDFDocument(url: fileURL) else {
                        throw PDFOperationError.couldNotOpen(fileURL)
                    }
                    let count = doc.pageCount
                    guard count > 0 else {
                        throw PDFOperationError.emptyPDF
                    }
                    let indices: [Int]
                    switch scopeSnapshot {
                    case .all:
                        indices = Array(0..<count)
                    case .range:
                        indices = try PageRangeParser.parse(rangeSnapshot, pageCount: count)
                    }
                    return try PDFExportSupport.data { out in
                        try PDFToolkit.rotate(
                            inputURL: fileURL,
                            outputURL: out,
                            pageIndices: indices,
                            quarterTurns: quarterTurnsSnapshot
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
