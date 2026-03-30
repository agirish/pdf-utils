import AppKit
import UniformTypeIdentifiers

/// Isolate `loadItem` async helpers on the main actor so `NSItemProvider` is not sent across executors
/// when SwiftUI’s drop handler resumes (providers are not `Sendable`).
@MainActor
extension NSItemProvider {
    func resolvePDFItemURL() async -> URL? {
        if let url = await loadItemURL(typeIdentifier: UTType.pdf.identifier) {
            return url.pathExtension.lowercased() == "pdf" ? url : nil
        }
        guard let url = await loadItemURL(typeIdentifier: UTType.fileURL.identifier) else { return nil }
        return url.pathExtension.lowercased() == "pdf" ? url : nil
    }

    func loadItemURL(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
