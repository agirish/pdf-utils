import Foundation
import PDFKit

/// Transfer wrapper for a `PDFDocument` produced on the PDF serial queue and consumed on the main
/// actor only — `PDFDocument` is not `Sendable` (same pattern as `PDFPageThumbnail`'s `NSImage`).
struct PDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument?
}

/// Runs PDFKit and related file work off the main thread without blocking the UI.
///
/// `PDFDocument` / `PDFPage` are **not** thread-safe. Using `DispatchQueue.global` allowed
/// concurrent PDF access and led to `EXC_BAD_ACCESS`. All work runs on one dedicated serial
/// queue so PDFKit sees a single thread at a time.
enum PDFBackgroundWork {
    private static let pdfSerialQueue = DispatchQueue(
        label: "org.pdfutils.pdfkit-serial",
        qos: .userInitiated
    )

    /// A lock-guarded flag bridging Swift-concurrency cancellation onto the GCD queue.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await run { _ in try work() }
    }

    /// Variant for long, abandonable work (thumbnail sweeps, previews). The closure runs on a GCD
    /// queue where `Task.isCancelled`/`Task.checkCancellation()` see **no current task** and are
    /// always inert — so the closure receives an `isCancelled` probe wired to the *calling* task's
    /// cancellation instead. Poll it between pages and bail early; otherwise a cancelled preview
    /// still renders to completion and every later operation queues behind the wasted work.
    static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pdfSerialQueue.async {
                    do {
                        continuation.resume(returning: try work(flag.isCancelled))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}
