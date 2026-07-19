import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The single operation the batch applies to every file. Mirrors the standalone tools' choices but
/// only the ones whose one configuration fits every file uniformly.
private enum BatchOpKind: String, CaseIterable, Identifiable {
    case compress
    case rotate
    case watermark
    case protect
    case unlock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compress: return "Compress"
        case .rotate: return "Rotate"
        case .watermark: return "Watermark"
        case .protect: return "Password Protect"
        case .unlock: return "Remove Password"
        }
    }
}

private enum BatchCompressMode: Hashable {
    case quality
    case targetSize
}

/// Quick-pick watermark colors, matching the Watermark tool's palette.
private struct BatchWatermarkColor: Identifiable, Hashable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }

    static let palette: [BatchWatermarkColor] = [
        BatchWatermarkColor(id: "gray", name: "Gray", red: 0.5, green: 0.5, blue: 0.5),
        BatchWatermarkColor(id: "black", name: "Black", red: 0.1, green: 0.1, blue: 0.1),
        BatchWatermarkColor(id: "red", name: "Red", red: 0.8, green: 0.12, blue: 0.12),
        BatchWatermarkColor(id: "blue", name: "Blue", red: 0.15, green: 0.32, blue: 0.82),
    ]
}

struct BatchToolView: View {
    @StateObject private var runner = BatchRunner()

    // Files
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var alertMessage: String?

    // Output
    @State private var outputDirectory: URL?

    // Operation selection + config
    @State private var opKind: BatchOpKind = .compress
    @State private var compressMode: BatchCompressMode = .quality
    @State private var quality: Double = 0.72
    @State private var targetMB: Double = 2
    @State private var quarterTurns = 1
    // Watermark
    @State private var watermarkText = "DRAFT"
    @State private var chosenColor: Color = BatchWatermarkColor.palette[0].color
    @State private var tiled = false
    @State private var fontSize: CGFloat = 48
    @State private var opacity: CGFloat = 0.25
    @State private var rotation: CGFloat = 45
    // Passwords
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPassword = ""

    private let accent = Tool.batch.accent
    private let watermarkPresets = ["CONFIDENTIAL", "DRAFT", "COPY"]

    // MARK: - Derived operation

    private var chosenRGB: (red: Double, green: Double, blue: Double) {
        let ns = NSColor(chosenColor).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    /// The configured operation, or nil when the current controls aren't valid to run yet.
    private var currentOperation: BatchOperation? {
        switch opKind {
        case .compress:
            switch compressMode {
            case .quality:
                return .compressQuality(quality: quality)
            case .targetSize:
                guard targetMB > 0 else { return nil }
                return .compressTarget(targetBytes: max(1, Int((targetMB * 1_048_576).rounded())))
            }
        case .rotate:
            return .rotate(quarterTurns: quarterTurns)
        case .watermark:
            let trimmed = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let rgb = chosenRGB
            return .watermark(WatermarkOptions(
                text: trimmed,
                fontSize: fontSize,
                opacity: opacity,
                rotationDegrees: rotation,
                red: rgb.red,
                green: rgb.green,
                blue: rgb.blue,
                tiled: tiled
            ))
        case .protect:
            guard passwordsMatch else { return nil }
            return .encrypt(password: newPassword)
        case .unlock:
            guard !currentPassword.isEmpty else { return nil }
            return .removePassword(password: currentPassword)
        }
    }

    private var canRun: Bool {
        !runner.isEmpty && outputDirectory != nil && currentOperation != nil && !runner.isRunning
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
            queueColumn
                .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                runner.addURLs(urls)
            case .failure(let err):
                alertMessage = err.localizedDescription
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

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow

                    Group {
                        if runner.isEmpty {
                            emptyDropZone
                        } else {
                            filesListCard
                        }
                    }
                    .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                        consumeDroppedProviders(providers)
                        return true
                    }

                    operationCard
                    configCard
                    outputCard
                }
                .padding(18)
                .formCard()
                .padding(12)
            }

            Divider()

            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: Tool.batch.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF files")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !runner.isEmpty {
                        Button("Clear all") { runner.clear() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(runner.isRunning)
                            .help("Remove every file from the queue")
                    }
                    Button("Add PDFs…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(runner.isRunning)
                }
            }
            Text(runner.isEmpty
                 ? "Drop several PDFs or add files, pick one operation, then run it across the whole set."
                 : "One operation runs on every file into your output folder. Originals are never changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: Tool.batch.symbolName)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop PDFs here or add files")
                .font(.title3.weight(.semibold))
            Text("Every file is processed with the same operation and settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDFs…") { showImporter = true }
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
        .accessibilityLabel("Queue is empty. Drop PDF files or choose PDFs.")
    }

    private var filesListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(runner.items.count) file\(runner.items.count == 1 ? "" : "s") queued")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            List {
                ForEach(runner.items) { item in
                    fileRow(for: item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 130, idealHeight: 200, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private func fileRow(for item: BatchRunner.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "doc.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                runner.remove(item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(runner.isRunning)
            .help("Remove from the queue")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.url.lastPathComponent)
    }

    // MARK: - Operation picker

    private var operationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operation")
                .font(.subheadline.weight(.semibold))
            Picker("Operation", selection: $opKind) {
                ForEach(BatchOpKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .disabled(runner.isRunning)
            Text("The same operation and settings are applied to every queued file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    @ViewBuilder
    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch opKind {
            case .compress: compressConfig
            case .rotate: rotateConfig
            case .watermark: watermarkConfig
            case .protect: protectConfig
            case .unlock: unlockConfig
            }
        }
        .padding(16)
        .formCard()
        .disabled(runner.isRunning)
    }

    private var compressConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Compression mode", selection: $compressMode) {
                Text("By quality").tag(BatchCompressMode.quality)
                Text("By target size").tag(BatchCompressMode.targetSize)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch compressMode {
            case .quality:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quality").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(qualityLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $quality, in: 0.2...1)
                }
            case .targetSize:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target size per file")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("2", value: $targetMB, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 88)
                            .multilineTextAlignment(.trailing)
                        Text("MB").foregroundStyle(.secondary)
                        Stepper("Target size", value: $targetMB, in: 0.1...500, step: 0.5)
                            .labelsHidden()
                    }
                    Text("Each file is compressed until it fits under this size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var qualityLabel: String {
        switch quality {
        case ..<0.45: return "Smaller file"
        case ..<0.75: return "Balanced"
        default: return "Higher quality"
        }
    }

    private var rotateConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotation")
                .font(.subheadline.weight(.semibold))
            Picker("Turns", selection: $quarterTurns) {
                Text("90° clockwise").tag(1)
                Text("180°").tag(2)
                Text("270° clockwise").tag(3)
            }
            .pickerStyle(.segmented)
            Text("Every page of every file is turned by this amount.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var watermarkConfig: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Watermark text").font(.subheadline.weight(.semibold))
                TextField("e.g. DRAFT", text: $watermarkText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    ForEach(watermarkPresets, id: \.self) { preset in
                        Button(preset) { watermarkText = preset }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    ForEach(BatchWatermarkColor.palette) { swatch in
                        Button {
                            chosenColor = swatch.color
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 26, height: 26)
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
                        Text("Custom…").font(.caption.weight(.medium))
                    }
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Layout").font(.subheadline.weight(.semibold))
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
    }

    private func swatchIsSelected(_ swatch: BatchWatermarkColor) -> Bool {
        let c = chosenRGB
        return abs(c.red - swatch.red) < 0.02
            && abs(c.green - swatch.green) < 0.02
            && abs(c.blue - swatch.blue) < 0.02
    }

    private var opacityPercentBinding: Binding<CGFloat> {
        Binding(get: { opacity * 100 }, set: { opacity = $0 / 100 })
    }

    private func slider(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var protectConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledSecureField("New password", text: $newPassword, prompt: "Required to open each PDF")
            labeledSecureField("Confirm password", text: $confirmPassword, prompt: "Re-enter the password")
            if !confirmPassword.isEmpty && !passwordsMatch {
                Label("Passwords don't match yet.", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Label("The same password locks every file. There is no recovery if you forget it.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unlockConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledSecureField("Current password", text: $currentPassword, prompt: "The password that opens these PDFs")
            Label("Every file is assumed to share this password. A file it doesn't open is marked failed.",
                  systemImage: "lock.open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledSecureField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Output folder

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output folder")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(accent)
                if let dir = outputDirectory {
                    Text(dir.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No folder chosen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(outputDirectory == nil ? "Choose…" : "Change…") { chooseOutputFolder() }
                    .disabled(runner.isRunning)
            }
            Text("Results are written here, named like the single tools (name-\(currentOperation?.suffixWord ?? "compressed").pdf). Existing files are numbered, never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Action bar

    private var actionBar: some View {
        Group {
            if runner.isRunning {
                Button(role: .destructive) {
                    runner.cancel()
                } label: {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Cancel").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                RunActionButton(title: runButtonTitle, canRun: canRun) {
                    startRun()
                }
            }
        }
        .padding(16)
        .toolActionBar()
    }

    private var runButtonTitle: String {
        let n = runner.items.count
        return n <= 1 ? "Run batch" : "Run batch on \(n) files"
    }

    // MARK: - Queue (main area)

    private var queueColumn: some View {
        VStack(spacing: 0) {
            if runner.isEmpty {
                EmptyStateView(
                    icon: Tool.batch.symbolName,
                    tint: accent,
                    title: "No files queued",
                    message: "Add PDFs on the left, choose an operation and an output folder, then run the batch to watch per-file progress here."
                )
            } else {
                queueContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryHeader

            List {
                ForEach(runner.items) { item in
                    queueRow(for: item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .padding(18)
        .formCard()
        .padding(12)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.title3.weight(.semibold))
                Spacer()
                if runner.doneCount > 0, let dir = runner.outputDirectory {
                    Button("Show in Finder") {
                        let files = runner.items.compactMap { item -> URL? in
                            if case .done(let url, _) = item.status { return url }
                            return nil
                        }
                        if files.isEmpty {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(files)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
            }

            ProgressView(value: runner.progressFraction)
                .tint(accent)

            Text(summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        parts.append("\(runner.doneCount) done")
        if runner.runningCount > 0 { parts.append("\(runner.runningCount) running") }
        parts.append("\(runner.pendingCount) waiting")
        if runner.failedCount > 0 { parts.append("\(runner.failedCount) failed") }
        var line = parts.joined(separator: " · ")
        let saved = runner.bytesSaved
        if saved > 0 {
            line += " — saved \(Self.formatBytes(saved))"
        }
        return line
    }

    private func queueRow(for item: BatchRunner.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon(for: item.status)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusPill(for: item)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.url.lastPathComponent), \(accessibilityStatus(for: item))")
    }

    @ViewBuilder
    private func statusIcon(for status: BatchRunner.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusPill(for item: BatchRunner.Item) -> some View {
        switch item.status {
        case .pending:
            pill("Waiting", color: .secondary)
        case .running:
            pill("Working…", color: accent)
        case .done(_, let outputBytes):
            pill(doneLabel(inputBytes: item.inputBytes, outputBytes: outputBytes), color: .green)
        case .failed:
            pill("Failed", color: .red)
        }
    }

    private func doneLabel(inputBytes: Int64?, outputBytes: Int64) -> String {
        if let inputBytes, inputBytes > outputBytes {
            return "−\(Self.formatBytes(inputBytes - outputBytes))"
        }
        return Self.formatBytes(outputBytes)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    private func accessibilityStatus(for item: BatchRunner.Item) -> String {
        switch item.status {
        case .pending: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard let directory = outputDirectory, let operation = currentOperation else { return }
        runner.run(operation: operation, into: directory)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the batch output"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        guard !runner.isRunning else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            runner.addURLs(urls)
        }
    }

    // MARK: - Formatting

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
