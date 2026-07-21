import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkToolView: View {
    @State private var text = "DRAFT"
    @State private var fontSize: CGFloat = 48
    @State private var opacity: CGFloat = 0.25
    @State private var rotation: CGFloat = 45
    @State private var tiled = false
    // Holds the actual chosen color (not just a palette id) so the ColorPicker can reach any color;
    // the quick swatches simply set this. RGB for the export is pulled from it at run time.
    @State private var chosenColor: Color = InkColor.with(id: "gray").color

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "watermarked.pdf"

    @StateObject private var runner = BatchRunner()

    /// The current watermark options as a batch operation, mirroring `runWatermark`. Nil when the
    /// text field is empty (there is nothing to stamp).
    private var currentBatchOperation: BatchOperation? {
        let rgb = chosenRGB
        return .watermarkConfig(
            text: text,
            fontSize: fontSize,
            opacity: opacity,
            rotationDegrees: rotation,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            tiled: tiled
        )
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

    private let textPresets = ["CONFIDENTIAL", "DRAFT", "COPY"]

    var body: some View {
        UnifiedFilePanel(
            runner: runner,
            tool: .watermark,
            singleActionTitle: "Watermark & save…",
            busy: $busy,
            makeOperation: { currentBatchOperation },
            fallbackSuffix: "watermarked",
            previewSubtitle: "The original pages. Your watermark is stamped on every page when you save.",
            runSingle: { url in await runWatermark(url) }
        ) {
            watermarkOptions
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
    }

    // MARK: - Options

    private var watermarkOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            livePreview

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
                .foregroundStyle(chosenColor)
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

    // MARK: - Single-file run

    @MainActor
    private func runWatermark(_ fileURL: URL) async {
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
        let rgb = chosenRGB
        let options = WatermarkOptions(
            text: trimmed,
            fontSize: fontSize,
            opacity: opacity,
            rotationDegrees: rotation,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            tiled: tiled
        )

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
