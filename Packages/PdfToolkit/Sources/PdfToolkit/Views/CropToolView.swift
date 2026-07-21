import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Which lever drives the crop: automatic content detection, or hand-typed margins.
private enum CropMode: Hashable {
    case auto
    case custom
}

struct CropToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    @State private var mode: CropMode = .auto
    @State private var padding: Double = 12
    @State private var unified = true
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
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

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
            SinglePDFPreviewColumn(
                thumbnails: thumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Pages before cropping. The trim applies to every page when you save.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to trim its margins.",
                emptySystemImage: "crop"
            )
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
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
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
                 : "Auto-detect finds the content on each page; custom margins trim fixed amounts from every page.")
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
                } else if !thumbnails.isEmpty {
                    Text("\(thumbnails.count) page\(thumbnails.count == 1 ? "" : "s")")
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
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .auto:
                autoControls
            case .custom:
                customControls
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

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim from each edge")
                .font(.subheadline.weight(.semibold))
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
            Text("Amounts are in points (72 pt = 1 inch, 28 pt ≈ 1 cm), measured on the page as displayed. The same trim applies to every page.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func insetField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .frame(width: 52, alignment: .leading)
            TextField("0", value: value, format: .number.precision(.fractionLength(0)))
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
            thumbnails = []
            isGeneratingPreviews = false
            return
        }
        thumbnails = []
        isGeneratingPreviews = true
        do {
            let loaded = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            guard !Task.isCancelled else { return }
            thumbnails = loaded
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-render; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            thumbnails = []
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

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        switch selectedMode {
                        case .auto:
                            try PDFToolkit.autoCrop(
                                inputURL: fileURL,
                                outputURL: out,
                                padding: paddingSnapshot,
                                unified: unifiedSnapshot
                            )
                        case .custom:
                            try PDFToolkit.crop(inputURL: fileURL, outputURL: out, insets: insetsSnapshot)
                        }
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
