import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which lever the user drives compression with: a direct quality slider, or a size budget the tool
/// works down to on its own.
private enum CompressMode: Hashable {
    case quality
    case targetSize
}

/// A named compression-strength preset — the friendly front end to the quality slider. Each card seeds
/// the quality value and advertises its own live projected output size, so the choice reads as an
/// outcome ("~2.3 MB, still sharp") instead of an abstract 0…1 number.
private struct CompressionStrength: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// Representative quality (0.2…1) this card stands for. Selecting the card snaps `quality` here; the
    /// buckets in `selected(for:)` decide which card is highlighted for any in-between slider value.
    let quality: Double

    /// Ordered gentlest → strongest. The quality points sit at the centres of the same three buckets the
    /// quality label and the Settings default already use, so cards, slider, and Settings speak one language.
    static let all: [CompressionStrength] = [
        CompressionStrength(id: "basic", title: "Basic", subtitle: "Good quality, light savings", quality: 0.85),
        CompressionStrength(id: "balanced", title: "Balanced", subtitle: "Smaller file, still sharp", quality: 0.6),
        CompressionStrength(id: "strong", title: "Strong", subtitle: "Smallest, slight quality loss", quality: 0.35),
    ]

    /// Which card a given quality reads as — the same thresholds as `qualityLabel`, so any slider value
    /// (including one seeded from Settings) lights up exactly one card instead of leaving none selected.
    static func selectedID(for quality: Double) -> String {
        switch quality {
        case ..<0.45: return "strong"
        case ..<0.75: return "balanced"
        default: return "basic"
        }
    }
}

/// The state of one projected-size computation. Estimates run on the shared serial PDF queue and are
/// debounced, so a cell can be waiting (`estimating`) or unresolvable (`unavailable`, e.g. a locked file)
/// as well as resolved.
private enum SizeEstimate: Equatable {
    case idle
    case estimating
    case ready(Int)
    case unavailable

    var bytes: Int? { if case .ready(let b) = self { return b } else { return nil } }
}

/// The payoff of a finished compression run: the real on-disk sizes before and after, plus where the
/// output landed so it can be revealed in Finder.
private struct CompressionResult: Equatable {
    let inputBytes: Int64
    let outputBytes: Int64
    let url: URL

    /// Fraction smaller, clamped at 0 so a file that didn't shrink reads as "0%" rather than negative.
    var reductionFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return max(0, Double(inputBytes - outputBytes) / Double(inputBytes))
    }

    var reductionPercent: Int { Int((reductionFraction * 100).rounded()) }
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
    /// Reveals the fine-grained quality slider. Collapsed by default so the strength cards are the
    /// primary control; the slider stays one click away as the advanced path (never removed).
    @State private var showAdvancedQuality = false

    // MARK: Live projected-size estimates
    //
    // Computed off the main thread on the serial PDF queue and cached per file. Two caches keyed by the
    // thing that determines the size — quality (×1000, to key a Double) and the target byte budget — so
    // flipping between already-seen settings is instant and only a genuinely new setting recomputes.
    @State private var qualityEstimates: [Int: SizeEstimate] = [:]
    @State private var targetEstimates: [Int: SizeEstimate] = [:]
    /// The file the caches belong to; when the selected file changes they're dropped.
    @State private var estimatedPath: String?

    /// The before/after readout of the most recent run, cleared when the selected file changes.
    @State private var lastResult: CompressionResult?
    /// Source size remembered while the save dialog is open, so the readout can be built from the
    /// exporter's success callback (where only the output data is otherwise in hand).
    @State private var pendingInputBytes: Int64?

    @StateObject private var runner = BatchRunner()

    @Environment(\.toolAccent) private var accent

    /// The lone queued file, or nil for the empty / batch cases — estimates and the readout are a
    /// single-file affair.
    private var singleFile: URL? {
        runner.items.count == 1 ? runner.items.first?.url : nil
    }

    /// Decimal MB (1,000,000) so the "MB" field, the "Now …" source hint (ByteCountFormatter `.file`),
    /// and the byte budget handed to the target sweep all refer to the same unit.
    private var targetBytes: Int {
        max(1, Int((targetMB * 1_000_000).rounded()))
    }

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
                if let inBytes = pendingInputBytes, let out = savedBytes {
                    lastResult = CompressionResult(inputBytes: inBytes, outputBytes: Int64(out), url: url)
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.compress.title) failed: \(err.localizedDescription)")
            }
            pendingInputBytes = nil
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
            // A different file (or none): the previous run's readout no longer describes what's loaded.
            lastResult = nil
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
        .task(id: estimateContext) {
            await refreshEstimates()
        }
    }

    /// Task key for the size lookup: the lone queued file's path, or empty when 0 or many files.
    private var singleSourcePath: String {
        runner.items.count == 1 ? (runner.items.first?.url.path ?? "") : ""
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = lastResult {
                resultReadout(result)
            }

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

    // MARK: Quality mode — strength cards + advanced slider

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CompressionStrength.all) { strength in
                strengthCard(strength)
            }

            DisclosureGroup(isExpanded: $showAdvancedQuality) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quality")
                            .font(.subheadline)
                        Spacer()
                        Text(qualityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $quality, in: 0.2...1)
                }
                .padding(.top, 6)
            } label: {
                Text("Fine-tune quality")
                    .font(.subheadline.weight(.medium))
            }
            .tint(accent)
        }
    }

    private func strengthCard(_ strength: CompressionStrength) -> some View {
        let isSelected = CompressionStrength.selectedID(for: quality) == strength.id
        return Button {
            // Tapping a card that isn't already the active bucket snaps quality to its representative,
            // so the projected size shown on that card is exactly what a run will produce. Re-tapping the
            // active card leaves a fine-tuned (custom) quality untouched.
            if !isSelected { quality = strength.quality }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(strength.title)
                        .font(.subheadline.weight(.semibold))
                    Text(strength.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                estimateBadge(estimate(for: strength), tint: isSelected ? accent : .secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color.primary.opacity(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.55) : Color.primary.opacity(0.06),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(strength.title), \(strength.subtitle)\(estimateAccessibility(for: strength))")
    }

    // MARK: Target-size mode

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

            if singleFile != nil {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Projected output")
                        .font(.subheadline)
                    Spacer()
                    estimateBadge(targetEstimates[targetBytes] ?? .idle, tint: accent)
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

    // MARK: - Before/after readout

    private func resultReadout(_ result: CompressionResult) -> some View {
        let shrank = result.outputBytes < result.inputBytes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                reductionRing(result)

                VStack(alignment: .leading, spacing: 4) {
                    Text(shrank ? "Compressed" : "Already optimized")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(Self.byteText(result.inputBytes))
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(Self.byteText(result.outputBytes))
                            .foregroundStyle(accent)
                    }
                    .font(.callout.weight(.medium).monospacedDigit())
                    Text(shrank
                         ? "\(result.reductionPercent)% smaller than the original"
                         : "This PDF was already about as small as it gets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(accent)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shrank
            ? "Compressed. \(Self.byteText(result.inputBytes)) to \(Self.byteText(result.outputBytes)), \(result.reductionPercent) percent smaller."
            : "Already optimized. Saved at \(Self.byteText(result.outputBytes)).")
    }

    private func reductionRing(_ result: CompressionResult) -> some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: 6)
            Circle()
                .trim(from: 0, to: result.reductionFraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(result.reductionPercent)%")
                    .font(.headline.weight(.bold).monospacedDigit())
                Text("smaller")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 66, height: 66)
        .accessibilityHidden(true)
    }

    // MARK: - Estimate presentation

    /// The estimate to show on a strength card: for the active card, the size at the *current* quality
    /// (which is what a run produces — including any fine-tuned value); for the others, the size at their
    /// own representative quality, previewing what switching would give.
    private func estimate(for strength: CompressionStrength) -> SizeEstimate {
        guard singleFile != nil else { return .idle }
        let key = CompressionStrength.selectedID(for: quality) == strength.id
            ? qKey(quality)
            : qKey(strength.quality)
        return qualityEstimates[key] ?? .idle
    }

    @ViewBuilder
    private func estimateBadge(_ estimate: SizeEstimate, tint: Color) -> some View {
        switch estimate {
        case .idle:
            EmptyView()
        case .estimating:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Estimating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let bytes):
            Text("≈ \(Self.byteText(Int64(bytes)))")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        case .unavailable:
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func estimateAccessibility(for strength: CompressionStrength) -> String {
        if case .ready(let bytes) = estimate(for: strength) {
            return ", about \(Self.byteText(Int64(bytes)))"
        }
        return ""
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Estimate engine

    /// Quality (0…1) → a stable integer cache key. 1/1000 steps are far finer than any perceptible
    /// size change, so this keys the Double cache without unbounded growth from slider jitter.
    private func qKey(_ quality: Double) -> Int { Int((quality * 1000).rounded()) }

    /// The inputs that change what the estimates should be. `.task(id:)` restarts `refreshEstimates`
    /// whenever any of these move, which both recomputes and — via the debounce inside — coalesces a
    /// storm of slider ticks into one computation on settle.
    private var estimateContext: String {
        "\(singleFile?.path ?? "")|\(mode == .quality ? "q" : "t")|\(qKey(quality))|\(targetBytes)"
    }

    @MainActor
    private func refreshEstimates() async {
        guard let url = singleFile else {
            qualityEstimates = [:]
            targetEstimates = [:]
            estimatedPath = nil
            return
        }
        // A new file invalidates every cached size.
        if estimatedPath != url.path {
            qualityEstimates = [:]
            targetEstimates = [:]
            estimatedPath = url.path
        }

        // Debounce: a slider drag or a target keystroke restarts this task, so only a value that stays
        // put for 300 ms survives the sleep to reach the serial (and, on large files, slow) PDF queue.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        switch mode {
        case .quality:
            // Compute the active card (at the current quality) plus each other card's representative —
            // exactly the numbers on screen, no more.
            let selectedID = CompressionStrength.selectedID(for: quality)
            var keys: Set<Int> = [qKey(quality)]
            for strength in CompressionStrength.all where strength.id != selectedID {
                keys.insert(qKey(strength.quality))
            }
            let toCompute = keys.filter { qualityEstimates[$0] == nil }
            for key in toCompute { qualityEstimates[key] = .estimating }
            for key in toCompute {
                // No post-await cancellation check: `compressData` runs to completion regardless (it
                // doesn't poll cancellation), and the result is keyed by quality — always a correct,
                // reusable cache entry — so storing it even on a superseded task avoids a stuck spinner.
                qualityEstimates[key] = await computeQualityEstimate(url: url, quality: Double(key) / 1000)
            }
        case .targetSize:
            let key = targetBytes
            guard targetEstimates[key] == nil else { return }
            targetEstimates[key] = .estimating
            targetEstimates[key] = await computeTargetEstimate(url: url, targetBytes: key)
        }
    }

    /// Runs the real quality-mode compression in memory and returns just its byte count — the exact size
    /// `runCompress`'s `.quality` path (which calls the same `compressData`) will write.
    private func computeQualityEstimate(url: URL, quality: Double) async -> SizeEstimate {
        do {
            let bytes = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess {
                    try PDFToolkit.compressData(inputURL: url, quality: quality).count
                }
            }
            return .ready(bytes)
        } catch {
            return .unavailable
        }
    }

    /// Runs the real target-size sweep in memory and returns just its byte count — the exact size the
    /// `.targetSize` run (same `compressToTargetData`) will write, which may sit under the target.
    private func computeTargetEstimate(url: URL, targetBytes: Int) async -> SizeEstimate {
        do {
            let bytes = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess {
                    try PDFToolkit.compressToTargetData(inputURL: url, targetBytes: targetBytes).count
                }
            }
            return .ready(bytes)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Single-file run

    @MainActor
    private func runCompress(_ fileURL: URL) async {
        busy = true
        lastResult = nil
        AppStateManager.shared.beginOperation(Tool.compress.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.compress.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
        let qualityValue = quality
        let selectedMode = mode
        let targetByteBudget = targetBytes
        let inputBytes = runner.items.first?.inputBytes
            ?? (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    switch selectedMode {
                    case .quality:
                        return try PDFToolkit.compressData(inputURL: fileURL, quality: qualityValue)
                    case .targetSize:
                        return try PDFToolkit.compressToTargetData(inputURL: fileURL, targetBytes: targetByteBudget)
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
            case .savedBeside(let url):
                // Read the real on-disk size (post metadata-strip, if that setting is on) so the
                // readout's "after" figure is the file the user actually has.
                let outputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    ?? Int64(data.count)
                if let inputBytes {
                    lastResult = CompressionResult(inputBytes: inputBytes, outputBytes: outputBytes, url: url)
                }
            case .present(let document, let name):
                // The save dialog decides the destination; stash the source size so its success
                // callback can build the readout from the saved data + URL.
                pendingInputBytes = inputBytes
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
