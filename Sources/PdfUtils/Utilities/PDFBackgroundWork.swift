import Foundation

/// Runs PDFKit / file IO off the main actor so the window stays responsive on large documents.
enum PDFBackgroundWork {
    static func run<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
