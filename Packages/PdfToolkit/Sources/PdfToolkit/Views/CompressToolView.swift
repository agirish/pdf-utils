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
///
/// Not `private`: `selectedID(for:)`'s bucket boundaries are pinned directly in the unit tests.
struct CompressionStrength: Identifiable {
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

    /// A settled, reusable size — the only state the estimate cache may skip recomputing. A cache miss,
    /// an `.estimating` marker stranded by a superseded task, and a (possibly transient) `.unavailable`
    /// are all recomputed, so no card is left spinning and a one-off failure gets another try.
    var isResolved: Bool { if case .ready = self { return true } else { return false } }
}

/// Identifies the compression setting a cached output belongs to, so a Save only reuses bytes that
/// were produced for the exact config being run.
private enum CompressCacheKey: Equatable {
    case quality(Int)   // qKey(quality)
    case target(Int)    // target byte budget
}

/// A cheap signature of the source file's content, so a Save can tell whether the file was edited on
/// disk (same path) since its bytes were cached — in which case the cached bytes are stale and Save
/// must recompress the current content, as it always did before caching existed.
private struct FileFingerprint: Equatable {
    let size: Int
    let modified: Date

    static func of(_ url: URL) -> FileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return FileFingerprint(size: size, modified: modified)
    }
}

/// The payoff of a finished compression run: the real on-disk sizes before and after, plus where the
/// output landed so it can be revealed in Finder.
///
/// Not `private`: the reduction math (zero-byte and non-shrinking edge cases) is unit-tested directly.
struct CompressionResult: Equatable {
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
    // Mirrors the Files-tab "Strip metadata on export" toggle so estimates track it: the saved file is
    // re-serialized post-strip when this is on, which shifts its size, so the projected sizes must too.
    @AppStorage(SettingsKeys.stripMetadataOnExport) private var stripMetadataOnExport = false
    @State private var mode: CompressMode = .quality
    // Target file size in megabytes for `.targetSize` mode. A plain, friendly unit for the field.
    @State private var targetMB: Double = 2
    @State private var busy = false
    // Per-page progress for a single-file run, so a long scan shows a determinate bar + Cancel
    // instead of an opaque spinner — the OCR tool's pattern. `progressTotal > 0` is what gates the
    // bar into view; both reset in `runCompress`'s defer.
    @State private var progressPage = 0
    @State private var progressTotal = 0
    /// The in-flight single-file compress, kept so Cancel (and leaving the screen) can abort it —
    /// compression holds the shared PDF serial queue, so an unabortable run starves every preview and
    /// every other tool until it finishes. Cancelling this task trips `PDFBackgroundWork`'s
    /// cancellation handler, which is the `isCancelled` probe the engine polls between pages.
    @State private var runTask: Task<Void, Never>?
    /// Bumped at every run start AND end. Progress callbacks hop to the main actor as unordered tasks;
    /// the generation check drops both stragglers from a finished run and out-of-order updates (paired
    /// with the monotonic page guard) — mirrors OCR exactly.
    @State private var progressGeneration = 0
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
    /// The strip-metadata setting the cached sizes were computed under; a change to it invalidates them
    /// all (every saved size shifts), exactly like a file change.
    @State private var estimatedStripMetadata = false

    /// The before/after readout of the most recent run, cleared when the selected file changes.
    @State private var lastResult: CompressionResult?
    /// Source size remembered while the save dialog is open, so the readout can be built from the
    /// exporter's success callback (where only the output data is otherwise in hand).
    @State private var pendingInputBytes: Int64?

    /// The exact compressed bytes the current setting's estimate already produced, so a Save at that
    /// same setting reuses them instead of running the whole compression (or target sweep) a second
    /// time. Pre-strip — `PDFExportCoordinator.route` applies any metadata strip — so it's independent
    /// of the strip setting; dropped when the selected file changes. The `fingerprint` guards against
    /// the file being edited on disk between the estimate and the Save.
    @State private var reusableOutput: (path: String, key: CompressCacheKey, fingerprint: FileFingerprint, data: Data)?

    @StateObject private var runner = BatchRunner()

    @Environment(\.toolAccent) private var accent

    /// The lone queued file, or nil for the empty / batch cases — estimates and the readout are a
    /// single-file affair.
    private var singleFile: URL? {
        runner.items.count == 1 ? runner.items.first?.url : nil
    }

    /// Decimal MB (1,000,000) so the "MB" field, the "Now …" source hint (ByteCountFormatter `.file`),
    /// and the byte budget handed to the target sweep all refer to the same unit. The clamp-and-convert
    /// lives in `BatchOperation.targetBytes(forMegabytes:)` — `targetMB` is bound to a free-entry field,
    /// and this property is read in `body`, so an out-of-range typed value would otherwise trap on the
    /// next render.
    private var targetBytes: Int {
        BatchOperation.targetBytes(forMegabytes: targetMB)
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
        .toolErrorAlert($alertMessage)
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
        // Leaving the screen mid-run must free the PDF serial queue, not let a multi-second compress
        // finish for a result nobody will see (the panel's own onDisappear only cancels batch runs).
        .onDisappear {
            runTask?.cancel()
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

            if busy && progressTotal > 0 {
                Divider()
                ProgressView(value: Double(progressPage), total: Double(progressTotal))
                    .tint(accent)
                HStack {
                    Text("Compressing… page \(progressPage) of \(progressTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") {
                        runTask?.cancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
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
        "\(singleFile?.path ?? "")|\(mode == .quality ? "q" : "t")|\(qKey(quality))|\(targetBytes)|\(stripMetadataOnExport ? "s" : "n")"
    }

    @MainActor
    private func refreshEstimates() async {
        guard let url = singleFile else {
            qualityEstimates = [:]
            targetEstimates = [:]
            estimatedPath = nil
            reusableOutput = nil
            return
        }
        // A new file — or a change to whether export strips metadata, which re-serializes and so
        // shifts every saved size — invalidates every cached estimate (the caches are keyed by
        // quality/target alone, not by either of those inputs).
        let strip = stripMetadataOnExport
        if estimatedPath != url.path || estimatedStripMetadata != strip {
            qualityEstimates = [:]
            targetEstimates = [:]
            // A genuinely different file also invalidates the reused bytes; a strip change does not,
            // since those bytes are pre-strip.
            if estimatedPath != url.path { reusableOutput = nil }
            estimatedPath = url.path
            estimatedStripMetadata = strip
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
            // Recompute only keys without a settled size: a `.ready` entry is reusable across quality
            // changes, while a `.estimating` stranded by a superseded task and a transient `.unavailable`
            // are both retried (so no card stays spinning and a one-off failure recovers).
            let toCompute = keys.filter { !(qualityEstimates[$0]?.isResolved ?? false) }
            guard !toCompute.isEmpty else { return }
            for key in toCompute { qualityEstimates[key] = .estimating }

            // All three cards in ONE enqueued queue slot, not one per card: three separate whole-document
            // compressions would monopolize the serial PDF queue that also renders thumbnails and runs
            // "Compress & save". The batch bails between passes when this task is superseded.
            //
            // Keep the compressed bytes for the *active* quality (the config a Save would run) so the
            // save reuses them; the other cards only need their size measured.
            let path = url.path
            let selectedKey = qKey(quality)
            let (sizes, selectedData) = await computeQualityEstimates(url: url, keys: toCompute, keepDataFor: selectedKey, stripMetadata: strip)
            // If the selection (or strip setting) moved on while this ran, its caches were reset; writing
            // file X's sizes into file Y's fresh cache would silently show stale numbers with no spinner.
            // Drop the whole batch — the now-current task recomputes what it needs.
            guard Self.shouldStoreEstimate(computedPath: path, currentPath: estimatedPath, isCancelled: Task.isCancelled)
            else { return }
            for key in toCompute {
                qualityEstimates[key] = sizes[key].map(SizeEstimate.ready) ?? .unavailable
            }
            if let selectedData, let fingerprint = FileFingerprint.of(url) {
                reusableOutput = (path, .quality(selectedKey), fingerprint, selectedData)
            }
        case .targetSize:
            let key = targetBytes
            guard !(targetEstimates[key]?.isResolved ?? false) else { return }
            targetEstimates[key] = .estimating
            let path = url.path
            let (estimate, data) = await computeTargetEstimate(url: url, targetBytes: key, stripMetadata: strip)
            guard Self.shouldStoreEstimate(computedPath: path, currentPath: estimatedPath, isCancelled: Task.isCancelled)
            else { return }
            targetEstimates[key] = estimate
            // Keep the swept-to-target bytes so a Save at this target reuses them instead of running
            // the whole progressive sweep again.
            if let data, let fingerprint = FileFingerprint.of(url) {
                reusableOutput = (path, .target(key), fingerprint, data)
            }
        }
    }

    /// Whether an estimate computed for `computedPath` should still be written into the cache: only when
    /// the caches still belong to that file (the selection hasn't moved on and reset them) and the task
    /// hasn't been superseded. Extracted as a pure static function so the cross-file guard that closes
    /// the stale-estimate race is unit-testable without driving the SwiftUI view. `nonisolated` so it's
    /// callable from a plain test (the view is inferred `@MainActor` via `View`).
    nonisolated static func shouldStoreEstimate(computedPath: String, currentPath: String?, isCancelled: Bool) -> Bool {
        !isCancelled && currentPath == computedPath
    }

    /// Measures the real `compressData` output size for each requested quality key — the exact bytes a
    /// run at that quality writes — inside a *single* enqueued serial-queue slot rather than one slot per
    /// card, so the badge estimates don't monopolize the queue that also renders thumbnails and runs the
    /// save. Cancellable *between* keys (a superseded task stops before the next pass; a single
    /// `compressData` pass itself doesn't poll), and strip-aware so the size matches the saved file when
    /// "Strip metadata on export" is on. Returns key → byte count for the passes that completed; a key
    /// absent from the result failed to compress and surfaces as `.unavailable`.
    private func computeQualityEstimates(url: URL, keys: Set<Int>, keepDataFor: Int, stripMetadata: Bool) async -> (sizes: [Int: Int], selectedData: Data?) {
        let sortedKeys = keys.sorted()
        do {
            return try await PDFBackgroundWork.run { isCancelled in
                try url.withSecurityScopedAccess {
                    var sizes: [Int: Int] = [:]
                    var selectedData: Data?
                    for key in sortedKeys {
                        if isCancelled() { break }
                        guard let data = try? PDFToolkit.compressData(inputURL: url, quality: Double(key) / 1000)
                        else { continue }
                        sizes[key] = Self.exportedByteCount(of: data, stripMetadata: stripMetadata)
                        // Retain only the active quality's bytes (the config a Save runs); the other
                        // cards are measured and their bytes dropped, so at most one blob is held.
                        if key == keepDataFor { selectedData = data }
                    }
                    return (sizes, selectedData)
                }
            }
        } catch {
            return ([:], nil)
        }
    }

    /// Runs the real target-size sweep in memory and returns just its byte count — the exact size the
    /// `.targetSize` run (same `compressToTargetData`) will write, which may sit under the target.
    private func computeTargetEstimate(url: URL, targetBytes: Int, stripMetadata: Bool) async -> (estimate: SizeEstimate, data: Data?) {
        do {
            // Both the size (post-strip) and the retained bytes (pre-strip) are produced inside the
            // one queue slot — `exportedByteCount` builds a PDFDocument when stripping, so it must
            // stay on the serial queue, never hop back to the main actor.
            let (bytes, data) = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess {
                    let data = try PDFToolkit.compressToTargetData(inputURL: url, targetBytes: targetBytes)
                    return (Self.exportedByteCount(of: data, stripMetadata: stripMetadata), data)
                }
            }
            return (.ready(bytes), data)
        } catch {
            return (.unavailable, nil)
        }
    }

    /// The size the estimate should report for produced `data`: the raw compressed bytes, or — when
    /// export strips metadata — the re-serialized post-strip bytes, so the badge equals the file
    /// `PDFExportCoordinator` actually writes. Must run on the PDF serial queue: `stripMetadata` builds
    /// a `PDFDocument`. Mirrors `PDFExportCoordinator.route`'s finalize step exactly, so the default
    /// (no-strip) estimate stays byte-for-byte equal to the saved output. `nonisolated` so it runs on
    /// the calling PDF-queue thread rather than hopping to the main actor (the view is inferred
    /// `@MainActor` via `View`) — PDFKit work must never leave that serial queue.
    private nonisolated static func exportedByteCount(of data: Data, stripMetadata: Bool) -> Int {
        stripMetadata ? PDFExportCoordinator.stripMetadata(data).count : data.count
    }

    // MARK: - Single-file run

    /// The panel awaits this for the one-file "Compress & save…" action. It owns the run as a
    /// cancellable `runTask` so the sidebar Cancel button (and leaving the screen) can abort the
    /// compression: the panel creates the task that calls this, which this view can't reach, so it
    /// wraps the actual work in its own task instead. Cancelling `runTask` trips
    /// `PDFBackgroundWork`'s cancellation handler — the `isCancelled` probe the engine polls between
    /// pages — exactly as OCR cancels its own `runTask`.
    @MainActor
    private func runCompress(_ fileURL: URL) async {
        let task = Task { await performCompress(fileURL) }
        runTask = task
        await task.value
    }

    @MainActor
    private func performCompress(_ fileURL: URL) async {
        busy = true
        lastResult = nil
        progressPage = 0
        progressTotal = 0
        progressGeneration += 1
        let generation = progressGeneration
        AppStateManager.shared.beginOperation(Tool.compress.title)
        defer {
            busy = false
            progressPage = 0
            progressTotal = 0
            // Invalidate straggler progress tasks still queued on the main actor — without this a late
            // hop could repaint a "page N of M" readout after the run already finished.
            progressGeneration += 1
            runTask = nil
            AppStateManager.shared.endOperation(Tool.compress.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
        let qualityValue = quality
        let selectedMode = mode
        let targetByteBudget = targetBytes
        let inputBytes = runner.items.first?.inputBytes
            ?? (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        // The badge estimate for the active setting already ran this exact compression; if its bytes
        // are still cached for this file and config — and the file on disk hasn't changed since —
        // reuse them rather than compressing again (the target sweep especially is not cheap to
        // repeat). The cached bytes are pre-strip, exactly what the compress calls return, so `route`
        // finalizes them identically.
        let runKey: CompressCacheKey = selectedMode == .quality ? .quality(qKey(qualityValue)) : .target(targetByteBudget)

        // Shared by both compress paths: hop each per-page report to the main actor, dropping
        // out-of-order and after-the-run updates (main-actor hops aren't FIFO). The monotonic
        // `page > progressPage` guard also keeps the bar from stepping backward on a target-size
        // sweep, where each lower-quality pass restarts at page 1: the bar fills on the first pass and
        // then holds at full through the remaining passes rather than jumping backward.
        let onProgress: @Sendable (Int, Int) -> Void = { page, total in
            Task { @MainActor in
                guard generation == progressGeneration, page > progressPage else { return }
                progressPage = page
                progressTotal = total
            }
        }

        do {
            let data: Data
            if let cached = reusableOutput, cached.path == fileURL.path, cached.key == runKey,
               let fingerprint = FileFingerprint.of(fileURL), fingerprint == cached.fingerprint {
                data = cached.data
            } else {
                data = try await PDFBackgroundWork.run { isCancelled in
                    try fileURL.withSecurityScopedAccess {
                        switch selectedMode {
                        case .quality:
                            return try PDFToolkit.compressData(
                                inputURL: fileURL, quality: qualityValue,
                                onProgress: onProgress, isCancelled: isCancelled
                            )
                        case .targetSize:
                            return try PDFToolkit.compressToTargetData(
                                inputURL: fileURL, targetBytes: targetByteBudget,
                                onProgress: onProgress, isCancelled: isCancelled
                            )
                        }
                    }
                }
            }
            // A Cancel that lands in the tail window — after the engine's last per-page cancel check
            // (or the instant cached-bytes reuse path, which polls nothing) but before we route — must
            // still abort: `route` would write the file, record `ActivityLog.recordSaved`, and reveal
            // it in Finder, contradicting "cancelling records nothing." Throw here into the silent
            // `CancellationError` catch below, before the generic error catch.
            try Task.checkCancellation()
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
        } catch is CancellationError {
            // Cancelled deliberately — the Cancel button or leaving the screen. Cancelling records
            // nothing: no error alert, no error log, exactly like OCR.
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.compress.title) failed: \(error.localizedDescription)")
        }
    }
}
