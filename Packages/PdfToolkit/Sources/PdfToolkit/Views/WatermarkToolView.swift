import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkToolView: View {
    @State private var mode: WatermarkOptions.Content = .text
    @State private var text = "DRAFT"
    @State private var fontSize: CGFloat = 48
    @State private var opacity: CGFloat = 0.25
    @State private var rotation: CGFloat = 45
    @State private var tiled = false
    /// Chosen text font family (empty = the bold system font, the original default). Stored as the
    /// family display name; the toolkit resolves it to a concrete font when stamping.
    @State private var fontFamily = ""
    // Holds the actual chosen color (not just a palette id) so the ColorPicker can reach any color;
    // the quick swatches simply set this. RGB for the export is pulled from it at run time.
    @State private var chosenColor: Color = InkColor.with(id: "gray").color

    // Image watermark state
    @State private var watermarkImage: WatermarkImage?
    @State private var imageName: String?
    /// A UI-only preview of the decoded logo (the swatch and the sidebar chip); the export uses the
    /// `CGImage` inside `watermarkImage`, never this.
    @State private var imageThumbnail: NSImage?
    @State private var imageScale: CGFloat = 0.4
    @State private var showImageImporter = false
    @State private var decodingImage = false

    // Page scope
    @State private var pageScope: PageScopeSelection = .all
    @State private var customRange = ""

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "watermarked.pdf"

    @StateObject private var runner = BatchRunner()

    /// Installed font families, read once per process — Watermark's native font menu (System default
    /// plus every installed family).
    private static let availableFamilies = NSFontManager.shared.availableFontFamilies

    enum PageScopeSelection: String, CaseIterable, Identifiable {
        case all
        case first
        case custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All pages"
            case .first: return "First page"
            case .custom: return "Custom"
            }
        }
    }

    private let textPresets = ["CONFIDENTIAL", "DRAFT", "COPY"]

    /// The current settings as `WatermarkOptions`, shared by the single-file run and the batch
    /// operation so both stamp exactly the same thing. Text is passed untrimmed here; the builder
    /// and the toolkit trim it.
    private var draftOptions: WatermarkOptions {
        let rgb = chosenRGB
        return WatermarkOptions(
            text: text,
            fontSize: fontSize,
            opacity: opacity,
            rotationDegrees: rotation,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            tiled: tiled,
            content: mode,
            fontName: fontFamily.isEmpty ? nil : fontFamily,
            image: mode == .image ? watermarkImage : nil,
            imageScale: imageScale,
            pageScope: resolvedScope
        )
    }

    private var resolvedScope: WatermarkOptions.PageScope {
        switch pageScope {
        case .all: return .all
        case .first: return .firstPageOnly
        case .custom: return .custom(customRange)
        }
    }

    /// The current watermark options as a batch operation, mirroring `runWatermark`. Nil when there
    /// is nothing to stamp (empty text, or no image chosen).
    private var currentBatchOperation: BatchOperation? {
        BatchOperation.watermarkConfig(draftOptions)
    }

    /// sRGB components of the chosen color, threaded into `WatermarkOptions` and mirrored by the live
    /// preview so both the on-screen sample and the stamped output use exactly the picked color.
    private var chosenRGB: (red: Double, green: Double, blue: Double) {
        let ns = NSColor(chosenColor).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    /// Whether a quick swatch matches the chosen color, so it can show a selection ring. Compared on
    /// RGB (with a small tolerance) since the color may have arrived from the ColorPicker.
    private func swatchIsSelected(_ swatch: InkColor) -> Bool {
        let c = chosenRGB
        return abs(c.red - swatch.red) < 0.02
            && abs(c.green - swatch.green) < 0.02
            && abs(c.blue - swatch.blue) < 0.02
    }

    var body: some View {
        UnifiedFilePanel(
            runner: runner,
            tool: .watermark,
            singleActionTitle: "Watermark & save…",
            busy: $busy,
            makeOperation: { currentBatchOperation },
            fallbackSuffix: "watermarked",
            previewSubtitle: "The original pages. Your watermark is stamped on the pages you choose when you save.",
            runSingle: { url in await runWatermark(url) }
        ) {
            watermarkOptions
        }
        .onChange(of: runner.items.first?.url) { _, _ in
            // A different document invalidates a typed page range (same rationale as Rotate/Delete
            // clearing on file switch): "1, 3-5" meant the old file's pages.
            customRange = ""
        }
        .fileImporter(
            isPresented: $showImageImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { loadWatermarkImage(url) }
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
        .toolErrorAlert($alertMessage)
    }

    // MARK: - Options

    private var watermarkOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker

            if mode == .text {
                textSource
            } else {
                imageSource
            }

            livePreview

            if mode == .text {
                colorSection
                fontSection
            }

            layoutSection
            pagesSection

            sizeSlider
            slider(title: "Opacity", value: opacityPercentBinding, range: 5...100, unit: "%")
            slider(title: "Angle", value: $rotation, range: -90...90, unit: "°")
        }
        .padding(16)
        .formCard()
    }

    private var modePicker: some View {
        Picker("Watermark type", selection: $mode) {
            Text("Text").tag(WatermarkOptions.Content.text)
            Text("Image").tag(WatermarkOptions.Content.image)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var textSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watermark text")
                .font(.subheadline.weight(.semibold))
            TextField("e.g. DRAFT", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(textPresets, id: \.self) { preset in
                    Button(preset) { text = preset }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption.weight(.semibold))
                        .help("Use “\(preset)” as the watermark text")
                }
            }
        }
    }

    private var imageSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watermark image")
                .font(.subheadline.weight(.semibold))
            if let imageName, let imageThumbnail {
                HStack(spacing: 12) {
                    Image(nsImage: imageThumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(imageName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let img = watermarkImage {
                            Text("\(img.cgImage.width) × \(img.cgImage.height)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Replace…") { showImageImporter = true }
                        .controlSize(.small)
                    Button {
                        clearWatermarkImage()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the image")
                }
            } else {
                Button {
                    showImageImporter = true
                } label: {
                    HStack(spacing: 8) {
                        if decodingImage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo.badge.plus")
                        }
                        Text(decodingImage ? "Loading…" : "Choose image or PDF…")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(decodingImage)
                Text("PNG, JPG, HEIC, or a PDF logo. Transparency is preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(InkColor.palette) { swatch in
                    Button {
                        chosenColor = swatch.color
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: InkColor.swatchDiameter, height: InkColor.swatchDiameter)
                            .overlay {
                                Circle().strokeBorder(
                                    swatchIsSelected(swatch) ? Color.primary.opacity(0.5) : .clear,
                                    lineWidth: 2.5
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }

                Divider().frame(height: 22)

                ColorPicker(selection: $chosenColor, supportsOpacity: false) {
                    Text("Custom…")
                        .font(.caption.weight(.medium))
                }
                .fixedSize()
                .help("Pick any color")
            }
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Font")
                .font(.subheadline.weight(.semibold))
            Picker("Font", selection: $fontFamily) {
                Text("System (default)").tag("")
                Divider()
                ForEach(Self.availableFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .help("Choose the font for the text watermark")
        }
    }

    private var layoutSection: some View {
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
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pages")
                .font(.subheadline.weight(.semibold))
            Picker("Pages", selection: $pageScope) {
                ForEach(PageScopeSelection.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if pageScope == .custom {
                TextField("e.g. 1, 3-5, 8", text: $customRange)
                    .textFieldStyle(.roundedBorder)
            }
            if runner.items.count >= 2 {
                Text("Applied to every file, following each file's own page count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sizeSlider: some View {
        if mode == .image {
            slider(title: "Size", value: imageScalePercentBinding, range: 5...100, unit: "%")
        } else {
            slider(title: "Size", value: $fontSize, range: 12...160, unit: "pt")
        }
    }

    private var livePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            previewContent
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch mode {
        case .text:
            Text(text.isEmpty ? "DRAFT" : text)
                .font(previewFont)
                .foregroundStyle(chosenColor)
                .opacity(opacity)
                .rotationEffect(.degrees(rotation))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(8)
        case .image:
            if let imageThumbnail {
                GeometryReader { geo in
                    Image(nsImage: imageThumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width * imageScale, height: geo.size.height * imageScale)
                        .opacity(opacity)
                        .rotationEffect(.degrees(rotation))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Choose an image to preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var previewFont: Font {
        let size = min(34, fontSize * 0.6)
        if fontFamily.isEmpty {
            return .system(size: size, weight: .bold)
        }
        return .custom(fontFamily, fixedSize: size)
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

    private var imageScalePercentBinding: Binding<CGFloat> {
        Binding(
            get: { imageScale * 100 },
            set: { imageScale = $0 / 100 }
        )
    }

    // MARK: - Image loading

    private func loadWatermarkImage(_ url: URL) {
        decodingImage = true
        let name = url.lastPathComponent
        Task {
            // Decode on the shared serial queue: the PDF-logo branch touches PDFKit, which is not
            // thread-safe, and this keeps every decode ordered with the rest of the PDF work.
            let decoded = try? await PDFBackgroundWork.run {
                PDFToolkit.watermarkImageSource(at: url)
            }
            await MainActor.run {
                decodingImage = false
                guard let decoded = decoded ?? nil else {
                    alertMessage = PDFOperationError.couldNotOpenImage(url).localizedDescription
                    return
                }
                watermarkImage = decoded
                imageName = name
                imageThumbnail = NSImage(
                    cgImage: decoded.cgImage,
                    size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
                )
            }
        }
    }

    private func clearWatermarkImage() {
        watermarkImage = nil
        imageName = nil
        imageThumbnail = nil
    }

    // MARK: - Single-file run

    @MainActor
    private func runWatermark(_ fileURL: URL) async {
        switch mode {
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                alertMessage = PDFOperationError.watermarkTextRequired.localizedDescription
                return
            }
        case .image:
            guard watermarkImage != nil else {
                alertMessage = PDFOperationError.watermarkImageRequired.localizedDescription
                return
            }
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.watermark.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.watermark.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-watermarked.pdf"
        let options = draftOptions

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.watermarkData(inputURL: fileURL, options: options)
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
