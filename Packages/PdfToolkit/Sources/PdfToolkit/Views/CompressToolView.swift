import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which lever the user drives compression with: a direct quality slider, or a size budget the tool
/// works down to on its own.
private enum CompressMode: Hashable {
    case quality
    case targetSize
}

struct CompressToolView: View {
    // Starts on (and writes back to) the Advanced "Default compression quality" — so the slider is
    // pre-selected and sticky across launches. Same 0.2…1 range as that control.
    @AppStorage(SettingsKeys.defaultCompressionQuality) private var quality: Double = 0.72
    @State private var mode: CompressMode = .quality
    // Target file size in megabytes for `.targetSize` mode. A plain, friendly unit for the field.
    @State private var targetMB: Double = 2
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "compressed.pdf"
    /// The single queued file's size, resolved once per file change — a computed property here used
    /// to stat the disk on every keystroke of the target-size field.
    @State private var sourceSizeText: String?

    @StateObject private var runner = BatchRunner()

    /// The current quality/target config as a batch operation, mirroring `runCompress`'s single-file
    /// choice. Nil only when the target-size field is emptied.
    private var currentBatchOperation: BatchOperation? {
        .compressConfig(usesTargetSize: mode == .targetSize, quality: quality, targetMegabytes: targetMB)
    }

    var body: some View {
        UnifiedFilePanel(
            runner: runner,
            tool: .compress,
            singleActionTitle: "Compress & save…",
            busy: $busy,
            makeOperation: { currentBatchOperation },
            fallbackSuffix: "compressed",
            previewSubtitle: "Pages in the file you’re about to compress.",
            runSingle: { url in await runCompress(url) }
        ) {
            controlsSection
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.compress.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.compress.title) failed: \(err.localizedDescription)")
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
        .task(id: singleSourcePath) {
            guard runner.items.count == 1, let url = runner.items.first?.url else {
                sourceSizeText = nil
                return
            }
            let size = await Task.detached(priority: .utility) {
                try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }.value
            guard !Task.isCancelled else { return }
            sourceSizeText = size.map {
                "Now \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))"
            }
        }
    }

    /// Task key for the size lookup: the lone queued file's path, or empty when 0 or many files.
    private var singleSourcePath: String {
        runner.items.count == 1 ? (runner.items.first?.url.path ?? "") : ""
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Compression mode", selection: $mode) {
                Text("By quality").tag(CompressMode.quality)
                Text("By target size").tag(CompressMode.targetSize)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .quality:
                qualityControls
            case .targetSize:
                targetSizeControls
            }
        }
        .padding(16)
        .formCard()
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quality")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(qualityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $quality, in: 0.2...1)
        }
    }

    private var targetSizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target size")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let label = sourceSizeText {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("2", value: $targetMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .multilineTextAlignment(.trailing)
                Text("MB")
                    .foregroundStyle(.secondary)
                Stepper("Target size", value: $targetMB, in: 0.1...500, step: 0.5)
                    .labelsHidden()
            }
            Text("Tries progressively lower quality until the file fits under your target.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var qualityLabel: String {
        switch quality {
        case ..<0.45: return "Smaller file"
        case ..<0.75: return "Balanced"
        default: return "Higher quality"
        }
    }

    // MARK: - Single-file run

    @MainActor
    private func runCompress(_ fileURL: URL) async {
        busy = true
        AppStateManager.shared.beginOperation(Tool.compress.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.compress.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
        let qualityValue = quality
        let selectedMode = mode
        // Decimal MB (1,000,000) so the field's "MB" label and the "Now …" source-size hint — which
        // ByteCountFormatter(.file) renders in decimal MB — refer to the same unit the target aims at.
        let targetBytes = max(1, Int((targetMB * 1_000_000).rounded()))

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    switch selectedMode {
                    case .quality:
                        return try PDFToolkit.compressData(inputURL: fileURL, quality: qualityValue)
                    case .targetSize:
                        return try PDFToolkit.compressToTargetData(inputURL: fileURL, targetBytes: targetBytes)
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.compress.title,
                defaultStem: "compressed",
                suffixWord: "compressed"
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
            ActivityLog.shared.error("\(Tool.compress.title) failed: \(error.localizedDescription)")
        }
    }
}
