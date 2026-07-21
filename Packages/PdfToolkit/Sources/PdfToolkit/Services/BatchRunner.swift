import Foundation
import PDFKit

/// One whole-document operation the Batch tool can apply uniformly to every file in a queue.
///
/// Only operations whose single configuration makes sense for *every* file are here — no per-file
/// page picking (Split/Extract/Delete/Reorder) and nothing that needs more than one input (Merge).
/// The associated values are the exact configuration the matching single tool captures, and every
/// payload is `Sendable`, so a value can be snapshotted on the main actor and handed straight to the
/// background PDF queue.
enum BatchOperation: Sendable {
    case compressQuality(quality: Double)
    case compressTarget(targetBytes: Int)
    case rotate(quarterTurns: Int)
    case watermark(WatermarkOptions)
    case encrypt(password: String)
    case removePassword(password: String)

    /// The single tool this operation belongs to, used to attribute Activity Log entries to the real
    /// tool (Compress, Rotate, …) now that multi-file runs live inside each tool rather than a
    /// separate "Batch" screen.
    var toolTitle: String {
        switch self {
        case .compressQuality, .compressTarget: return Tool.compress.title
        case .rotate: return Tool.rotate.title
        case .watermark: return Tool.watermark.title
        case .encrypt, .removePassword: return Tool.protect.title
        }
    }

    /// Filename suffix appended to each output, reusing the single tools' convention (`-compressed`,
    /// `-rotated`, …) so a batch result is named exactly like the one-off tool would name it.
    var suffixWord: String {
        switch self {
        case .compressQuality, .compressTarget: return "compressed"
        case .rotate: return "rotated"
        case .watermark: return "watermarked"
        case .encrypt: return "protected"
        case .removePassword: return "unlocked"
        }
    }

    /// The pure output filename for one input: `Report.pdf` → `Report-compressed.pdf`, or `Report.pdf`
    /// when the "Add a suffix to output names" setting is off. Routed through
    /// ``PDFExportCoordinator/suggestedFilename(stem:suffixWord:defaults:)`` so a batch names its files
    /// exactly like the single-file tools (which honor the same setting) instead of always suffixing.
    /// Uniqueness against files already in the destination is applied separately (see ``BatchRunner``
    /// via ``PDFExportCoordinator/uniqueURL(inDirectory:filename:fileManager:)``); this stays testable
    /// with no filesystem (the toggle is injectable via `defaults`).
    func outputFilename(forInputNamed inputName: String, defaults: UserDefaults = .standard) -> String {
        let stem = (inputName as NSString).deletingPathExtension
        let safeStem = stem.isEmpty ? "document" : stem
        return PDFExportCoordinator.suggestedFilename(stem: safeStem, suffixWord: suffixWord, defaults: defaults)
    }

    /// Dispatches to the matching `PDFToolkit` call and writes the result to `outputURL`; callers
    /// wrap this in the right security scope. A thin wrapper over ``applyData(_:inputURL:)`` so the
    /// operation → toolkit mapping never grows a parallel switch.
    static func apply(_ operation: BatchOperation, inputURL: URL, outputURL: URL) throws {
        try PDFToolkit.requireDistinctOutput(outputURL, from: [inputURL])
        try PDFToolkit.writeOutput(try applyData(operation, inputURL: inputURL), to: outputURL)
    }

    /// Dispatches to the matching `PDFToolkit` core and returns the result's bytes. The single
    /// place the operation → toolkit mapping lives, so the runner never grows a parallel switch.
    /// Reads the input; callers wrap this in the right security scope. Rotation covers *all* pages,
    /// so the page count is read here per file (each document has its own length).
    static func applyData(_ operation: BatchOperation, inputURL: URL) throws -> Data {
        switch operation {
        case .compressQuality(let quality):
            return try PDFToolkit.compressData(inputURL: inputURL, quality: quality)
        case .compressTarget(let targetBytes):
            return try PDFToolkit.compressToTargetData(inputURL: inputURL, targetBytes: targetBytes)
        case .rotate(let quarterTurns):
            guard let count = PDFToolkit.pageCount(at: inputURL) else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            return try PDFToolkit.rotateData(
                inputURL: inputURL,
                pageIndices: Array(0..<count),
                quarterTurns: quarterTurns
            )
        case .watermark(let options):
            return try PDFToolkit.watermarkData(inputURL: inputURL, options: options)
        case .encrypt(let password):
            return try PDFToolkit.encryptData(inputURL: inputURL, password: password)
        case .removePassword(let password):
            return try PDFToolkit.removePasswordData(inputURL: inputURL, password: password)
        }
    }
}

/// Drives a batch: holds the queue of files and their live per-file state, processes them one at a
/// time off the main thread, and lets the run be cancelled between files.
///
/// `@MainActor` because `@Published items` drives the SwiftUI queue view. Each file's PDF work runs
/// on the shared serial `PDFBackgroundWork` queue (PDFKit is not thread-safe), wrapped in security
/// scope for the source and destination folder. Processing is strictly sequential: it keeps the
/// per-file output-name uniqueness correct (an earlier result is already on disk when the next name
/// is derived) and keeps PDFKit on one document at a time.
@MainActor
final class BatchRunner: ObservableObject {
    /// The lifecycle of one queued file, mirrored into the queue view.
    enum Status: Equatable {
        case pending
        case running
        case done(outputURL: URL, outputBytes: Int64)
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var inputBytes: Int64?
        var status: Status = .pending
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    /// The folder the last (or in-progress) run wrote into — surfaced so the queue can offer a
    /// "Show in Finder" affordance once files land.
    @Published private(set) var outputDirectory: URL?

    private var runTask: Task<Void, Never>?

    // MARK: - Queue editing (only while idle)

    var isEmpty: Bool { items.isEmpty }

    /// Appends the PDFs not already queued (compared by standardized path), best-effort reading each
    /// one's size for the later size-delta display.
    func addURLs(_ urls: [URL]) {
        guard !isRunning else { return }
        let existing = Set(items.map { $0.url.standardizedFileURL })
        for url in urls where !existing.contains(url.standardizedFileURL) {
            items.append(Item(url: url, inputBytes: Self.fileSize(of: url)))
        }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
    }

    // MARK: - Aggregate summary

    var doneCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var runningCount: Int { items.filter { $0.status == .running }.count }
    var pendingCount: Int { items.filter { $0.status == .pending }.count }

    /// Fraction of the queue that has reached a terminal state (done or failed), 0…1, for the
    /// aggregate bar. Zero when the queue is empty.
    var progressFraction: Double {
        guard !items.isEmpty else { return 0 }
        return Double(doneCount + failedCount) / Double(items.count)
    }

    /// Net bytes reclaimed across finished files (`input − output` summed). Negative for operations
    /// that grow the file (encrypt, watermark); the view only advertises it when positive.
    var bytesSaved: Int64 {
        items.reduce(0) { total, item in
            guard case .done(_, let outBytes) = item.status, let inBytes = item.inputBytes else { return total }
            return total + (inBytes - outBytes)
        }
    }

    // MARK: - Run / cancel

    /// Where a run writes each output. `folder` puts every result in one directory (the "Ask each time"
    /// path prompts for it once); `besideEachSource` writes each result next to its own input, honoring
    /// the "Save beside original" setting for a many-file run just as the single-file coordinator does.
    enum Destination: Equatable {
        case folder(URL)
        case besideEachSource
    }

    /// Resets every item to pending and processes the queue with `operation`, writing each result into
    /// `directory`. Kept for the existing "one output folder" callers (and tests).
    func run(operation: BatchOperation, into directory: URL) {
        run(operation: operation, destination: .folder(directory))
    }

    /// Resets every item to pending and processes the queue with `operation`, writing each result per
    /// `destination`. Returns immediately; progress is published as it goes. A second call is ignored
    /// while a run is in flight.
    func run(operation: BatchOperation, destination: Destination) {
        guard !isRunning, !items.isEmpty else { return }
        // A single output folder is a meaningful "reveal target"; beside-each-source has none, so the
        // queue reveals the produced files directly instead.
        outputDirectory = { if case .folder(let dir) = destination { return dir } else { return nil } }()
        for index in items.indices {
            items[index].status = .pending
        }
        isRunning = true

        // Register like every single-file operation does, so ⌘Q during a run raises the
        // "Operation in Progress" warning instead of terminating mid-file.
        let operationName = "\(operation.toolTitle) (multiple files)"
        AppStateManager.shared.beginOperation(operationName)

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.process(operation: operation, destination: destination)
            self.isRunning = false
            self.runTask = nil
            AppStateManager.shared.endOperation(operationName)
        }
    }

    /// Requests cancellation. The in-flight file finishes (a single PDF op is atomic), then the loop
    /// stops before the next file; remaining files stay pending.
    func cancel() {
        runTask?.cancel()
    }

    private func process(operation: BatchOperation, destination: Destination) async {
        // Read once on the main actor; each file's finalize honors the same Files-tab setting the
        // single-file coordinator applies. Skipping this made "Strip metadata on export" silently
        // ignored for exactly the runs that touch the most files.
        let stripMetadata = UserDefaults.standard.bool(forKey: SettingsKeys.stripMetadataOnExport)

        for index in items.indices {
            if Task.isCancelled { break }
            let item = items[index]
            items[index].status = .running

            let filename = operation.outputFilename(forInputNamed: item.url.lastPathComponent)
            let inputURL = item.url
            // Beside-each-source lands each result in its own input's folder; a single folder lands
            // them all together. Uniqueness (see below) is still per destination directory.
            let directory: URL
            switch destination {
            case .folder(let dir): directory = dir
            case .besideEachSource: directory = inputURL.deletingLastPathComponent()
            }

            do {
                let result: (url: URL, bytes: Int64) = try await PDFBackgroundWork.run {
                    try URLCollectionSecurityScope.withAccess([inputURL, directory]) {
                        // Materialize in memory, finalize, then land atomically — the same shape
                        // as the single-file coordinator. Writing the destination directly meant
                        // a crash or force-quit mid-file left a truncated PDF at its final
                        // user-visible name.
                        let produced = try BatchOperation.applyData(operation, inputURL: inputURL)
                        let finalized = stripMetadata ? PDFExportCoordinator.stripMetadata(produced) : produced
                        let outputURL = PDFExportCoordinator.uniqueURL(inDirectory: directory, filename: filename)
                        try finalized.write(to: outputURL, options: .atomic)
                        return (outputURL, Int64(finalized.count))
                    }
                }
                items[index].status = .done(outputURL: result.url, outputBytes: result.bytes)
                ActivityLog.shared.recordSaved(operation.toolTitle, to: result.url, bytes: Int(result.bytes))
            } catch {
                items[index].status = .failed(error.localizedDescription)
                ActivityLog.shared.error("\(operation.toolTitle) failed for \(inputURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // A run cancelled mid-queue breaks the loop before touching the remaining files, leaving them
        // `.pending`. Surface that incomplete outcome as a WARN so it shows at the "Warnings and
        // errors" level: the per-file ERRORs only account for files that were attempted and failed,
        // never ones the cancellation skipped.
        let notProcessed = items.filter { $0.status == .pending }.count
        if notProcessed > 0 {
            let noun = notProcessed == 1 ? "file" : "files"
            ActivityLog.shared.warning("\(operation.toolTitle): batch stopped early — \(notProcessed) of \(items.count) \(noun) not processed")
        }

        // One after-export action for the whole run, at the end. Per-file firing activated Finder
        // (or opened a Preview window) once per file, stealing focus for the entire run; the
        // action's own multi-file branch exists precisely to reveal a batch in one shot.
        let produced = items.compactMap { item -> URL? in
            if case .done(let url, _) = item.status { return url }
            return nil
        }
        if !produced.isEmpty {
            AfterExportAction.current().perform(on: produced)
        }
    }

    // MARK: - Helpers

    nonisolated static func fileSize(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}
