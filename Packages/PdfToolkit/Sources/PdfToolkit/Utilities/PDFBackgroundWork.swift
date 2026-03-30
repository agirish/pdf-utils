import Foundation

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

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            pdfSerialQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
