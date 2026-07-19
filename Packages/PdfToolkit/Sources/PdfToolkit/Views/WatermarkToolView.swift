import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct WatermarkColor: Identifiable, Hashable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static let palette: [WatermarkColor] = [
        WatermarkColor(id: "gray", name: "Gray", red: 0.5, green: 0.5, blue: 0.5),
        WatermarkColor(id: "black", name: "Black", red: 0.1, green: 0.1, blue: 0.1),
        WatermarkColor(id: "red", name: "Red", red: 0.8, green: 0.12, blue: 0.12),
        WatermarkColor(id: "blue", name: "Blue", red: 0.15, green: 0.32, blue: 0.82),
    ]
}

struct WatermarkToolView: View {
    @State private var inputURL: URL?
    @State private var text = "DRAFT"
    @State private var fontSize: CGFloat = 48
    @State private var opacity: CGFloat = 0.25
    @State private var rotation: CGFloat = 45
    @State private var tiled = false
    @State private var colorID = "gray"

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "watermarked.pdf"
    @State private var isDropTargeted = false
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var selectedColor: WatermarkColor {
        WatermarkColor.palette.first { $0.id == colorID } ?? WatermarkColor.palette[0]
    }

    private var canRun: Bool {
        inputURL != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
            SinglePDFPreviewColumn(
                thumbnails: thumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: Tool.watermark.accent,
                previewSubtitle: "The original pages. Your watermark is stamped on every page when you save.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to watermark.",
                emptySystemImage: "signature"
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.watermark.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.watermark.title) failed: \(err.localizedDescription)")
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

                    if inputURL != nil {
                        watermarkOptions
                    }
                }
                .padding(18)
                .formCard()
                .padding(12)
            }

            Divider()

            RunActionButton(title: "Watermark & save…", busy: busy, canRun: canRun) {
                Task { await runWatermark() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "signature")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.watermark.accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") { inputURL = nil }
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
                 ? "Drop a PDF or add a file, then set your watermark text and style."
                 : "The watermark is baked into a new PDF. The original file is not changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "signature")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.watermark.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Preview pages on the right, then stamp text across every page.")
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
                .foregroundStyle(isDropTargeted ? Tool.watermark.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.watermark.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.watermark.accent)
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

    private var watermarkOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Watermark text")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. DRAFT", text: $text)
                    .textFieldStyle(.roundedBorder)
            }

            livePreview

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    ForEach(WatermarkColor.palette) { swatch in
                        Button {
                            colorID = swatch.id
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle().strokeBorder(
                                        colorID == swatch.id ? Color.primary.opacity(0.5) : .clear,
                                        lineWidth: 2.5
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Layout")
                    .font(.subheadline.weight(.semibold))
                Picker("Layout", selection: $tiled) {
                    Text("Centered").tag(false)
                    Text("Tiled").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            slider(title: "Size", value: $fontSize, range: 12...160, unit: "pt")
            slider(title: "Opacity", value: opacityPercentBinding, range: 5...100, unit: "%")
            slider(title: "Angle", value: $rotation, range: -90...90, unit: "°")
        }
        .padding(16)
        .formCard()
    }

    private var livePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            Text(text.isEmpty ? "DRAFT" : text)
                .font(.system(size: min(34, fontSize * 0.6), weight: .bold))
                .foregroundStyle(selectedColor.color)
                .opacity(opacity)
                .rotationEffect(.degrees(rotation))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(8)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func slider(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var opacityPercentBinding: Binding<CGFloat> {
        Binding(
            get: { opacity * 100 },
            set: { opacity = $0 / 100 }
        )
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            thumbnails = []
            isGeneratingPreviews = false
            return
        }
        isGeneratingPreviews = true
        defer { isGeneratingPreviews = false }
        do {
            thumbnails = try await PDFPageThumbnailLoader.loadAllPages(from: url)
        } catch {
            thumbnails = []
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
    private func runWatermark() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = PDFOperationError.watermarkTextRequired.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.watermark.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.watermark.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-watermarked.pdf"
        let swatch = selectedColor
        let options = WatermarkOptions(
            text: trimmed,
            fontSize: fontSize,
            opacity: opacity,
            rotationDegrees: rotation,
            red: swatch.red,
            green: swatch.green,
            blue: swatch.blue,
            tiled: tiled
        )

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        try PDFToolkit.watermark(inputURL: fileURL, outputURL: out, options: options)
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.watermark.title,
                defaultStem: "watermarked",
                suffixWord: "watermarked"
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
            ActivityLog.shared.error("\(Tool.watermark.title) failed: \(error.localizedDescription)")
        }
    }
}
