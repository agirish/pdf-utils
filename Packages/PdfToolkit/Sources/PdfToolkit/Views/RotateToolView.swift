import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct RotateToolView: View {
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var quarterTurns = 1
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "rotated.pdf"

    @StateObject private var runner = BatchRunner()

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
        UnifiedFilePanel(
            runner: runner,
            tool: .rotate,
            singleActionTitle: "Rotate & save…",
            busy: $busy,
            makeOperation: { .rotateConfig(quarterTurns: quarterTurns) },
            fallbackSuffix: "rotated",
            previewSubtitle: "Thumbnails show every page; only the pages you choose below are rotated in the new PDF.",
            runSingle: { url in await runRotate(url) }
        ) {
            rotateConfig
        }
        .onChange(of: runner.items.first?.url) { _, _ in
            // A different document invalidates a typed page range (same rationale as
            // Extract/Delete clearing on file switch): "1, 3-5" meant the old file's pages, and
            // against the new one it either errors or silently rotates the wrong set.
            rangeText = ""
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.rotate.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.rotate.title) failed: \(err.localizedDescription)")
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
    }

    // MARK: - Config (count-aware: page range for one file, all-pages note for many)

    @ViewBuilder
    private var rotateConfig: some View {
        if runner.items.count >= 2 {
            rotationSection
            allPagesNoteCard
        } else {
            pagesSection
            rotationSection
        }
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pages")
                .font(.subheadline.weight(.semibold))
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
    }

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rotation")
                .font(.subheadline.weight(.semibold))
            Picker("Turns", selection: $quarterTurns) {
                Text("90° clockwise").tag(1)
                Text("180°").tag(2)
                Text("270° clockwise").tag(3)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .formCard()
    }

    private var allPagesNoteCard: some View {
        Label("Every page of every file is rotated. Page ranges aren't available with more than one file.",
              systemImage: "info.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .formCard()
    }

    // MARK: - Single-file run

    @MainActor
    private func runRotate(_ fileURL: URL) async {
        busy = true
        AppStateManager.shared.beginOperation(Tool.rotate.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.rotate.title)
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
                        // The user explicitly chose "Page range": an empty field must error, not
                        // quietly mean "all pages" — that surprise rotated whole documents.
                        indices = try PageRangeParser.parse(
                            rangeSnapshot,
                            pageCount: count,
                            emptyMeansAllPages: false
                        )
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
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.rotate.title,
                defaultStem: "rotated",
                suffixWord: "rotated"
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
            ActivityLog.shared.error("\(Tool.rotate.title) failed: \(error.localizedDescription)")
        }
    }
}
