import AppKit
import UniformTypeIdentifiers

/// Isolate `loadItem` async helpers on the main actor so `NSItemProvider` is not sent across executors
/// when SwiftUI’s drop handler resumes (providers are not `Sendable`).
@MainActor
extension NSItemProvider {
    func resolvePDFItemURL() async -> URL? {
        // A provider that matched UTType.pdf IS a PDF — don't second-guess it by extension, or
        // valid extensionless/renamed PDFs get silently rejected on drop.
        if let url = await loadItemURL(typeIdentifier: UTType.pdf.identifier) {
            return url
        }
        // Generic file URLs carry no type promise; accept by extension or by content type.
        guard let url = await loadItemURL(typeIdentifier: UTType.fileURL.identifier) else { return nil }
        if url.pathExtension.lowercased() == "pdf" { return url }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .pdf) == true ? url : nil
    }

    /// Image-flavored twin of ``resolvePDFItemURL()`` for the Images to PDF drop target.
    func resolveImageItemURL() async -> URL? {
        if let url = await loadItemURL(typeIdentifier: UTType.image.identifier) {
            return url
        }
        guard let url = await loadItemURL(typeIdentifier: UTType.fileURL.identifier) else { return nil }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .image) == true { return url }
        // Fall back to the extension for volumes that don't report a content type.
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? url : nil
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
