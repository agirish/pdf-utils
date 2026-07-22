import Foundation
import PDFKit

/// The single place tool output is finalized and saved, so every tool honors the Files-tab settings
/// (strip metadata, filename suffix, save location, after-export action) identically instead of each
/// re-implementing them. Single-file tools hand their produced `Data` to ``route(data:source:toolTitle:defaultStem:suffixWord:)``
/// and either get a "already saved beside the source" result or a document to feed their own save
/// dialog; the multi-file tools (Merge, Split) reuse the naming and after-export pieces directly.
enum PDFExportCoordinator {
    /// What ``route`` decided. `savedBeside` means the file is already on disk (logged, after-export
    /// action run); `present` means the caller should show its save dialog with this document + name.
    enum Outcome {
        case savedBeside(URL)
        case present(document: PDFFileDocument, suggestedName: String)
    }

    /// Finalizes produced PDF `data` and routes it to disk per the current settings.
    ///
    /// - When "Save beside original" is off (default), returns `.present` so the caller's
    ///   `fileExporter`/save panel handles the destination.
    /// - When on and a `source` exists, writes into the source's folder under a non-clashing name and
    ///   returns `.savedBeside`.
    ///
    /// Metadata stripping and the disk write both run off the main thread.
    ///
    /// `applyMetadataStrip` lets the Clean Metadata tool opt out of the global "Strip metadata on
    /// export" setting: its output IS the user's deliberately chosen metadata, and the setting would
    /// silently erase fields they just typed. Every other tool leaves it at the default.
    @MainActor
    static func route(
        data: Data,
        source: URL?,
        toolTitle: String,
        defaultStem: String,
        suffixWord: String,
        applyMetadataStrip: Bool = true,
        defaults: UserDefaults = .standard
    ) async throws -> Outcome {
        let finalized: Data = applyMetadataStrip
            && defaults.bool(forKey: SettingsKeys.stripMetadataOnExport)
            ? try await PDFBackgroundWork.run { stripMetadata(data) }
            : data

        let stem = source?.deletingPathExtension().lastPathComponent ?? defaultStem
        let filename = suggestedFilename(stem: stem, suffixWord: suffixWord, defaults: defaults)

        guard SaveLocation.current(defaults) == .besideOriginal, let source else {
            return .present(document: PDFFileDocument(data: finalized), suggestedName: filename)
        }

        let directory = source.deletingLastPathComponent()
        let destination = uniqueURL(inDirectory: directory, filename: filename)
        try await writeOffMain(finalized, to: destination)
        ActivityLog.shared.recordSaved(toolTitle, to: destination, bytes: finalized.count)
        AfterExportAction.current(defaults).perform(on: [destination])
        return .savedBeside(destination)
    }

    /// Pure disk I/O, deliberately NOT `PDFBackgroundWork`: a plain `Data` write touches no PDFKit
    /// object, and parking it on the single PDF serial queue made every "beside original" export
    /// queue behind — and block — rendering work. Nonisolated async runs on the global concurrent
    /// executor, off the main actor and off the PDF queue.
    private nonisolated static func writeOffMain(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    /// Records the save and runs the after-export action for a file the caller just wrote through its
    /// own save dialog (the "Ask each time" path). Replaces the bare `recordSaved` call at each
    /// tool's `fileExporter`/panel success site.
    @MainActor
    static func didExport(to url: URL, toolTitle: String, bytes: Int?, detail: String? = nil) {
        ActivityLog.shared.recordSaved(toolTitle, to: url, bytes: bytes, detail: detail)
        AfterExportAction.current().perform(on: [url])
    }

    // MARK: Naming

    /// `Report-compressed.pdf` when the suffix setting is on (default), else `Report.pdf`.
    static func suggestedFilename(stem: String, suffixWord: String, defaults: UserDefaults = .standard) -> String {
        let appendSuffix = defaults.object(forKey: SettingsKeys.appendFilenameSuffix) as? Bool ?? true
        if appendSuffix, !suffixWord.isEmpty {
            return "\(stem)-\(suffixWord).pdf"
        }
        return "\(stem).pdf"
    }

    /// `dir/filename`, or `dir/name 2.pdf`, `name 3.pdf`… if that already exists — so "beside original"
    /// never overwrites a prior output (and, with a suffix present, never the source either).
    static func uniqueURL(inDirectory directory: URL, filename: String, fileManager: FileManager = .default) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    // MARK: Metadata

    /// Returns `data` with all document metadata cleared — the Info dictionary (author, title, creator,
    /// dates, keywords) AND the catalog XMP `/Metadata` packet, which a plain Info clear leaves behind
    /// (see ``PDFToolkit/dataStrippingHiddenMetadata(from:applying:)``). Fail-safe: any failure returns
    /// the input unchanged rather than losing the export.
    ///
    /// The catalog XMP can only be dropped by rebuilding the document, so a form-bearing PDF keeps the
    /// lighter Info-only clear (the rebuild would flatten its fields) and an encrypted PDF (the Protect
    /// tool's password mode) is returned untouched — re-serializing it would corrupt its encryption.
    static func stripMetadata(_ data: Data) -> Data {
        guard let doc = PDFDocument(data: data), !doc.isEncrypted, !doc.isLocked else { return data }
        if !PDFToolkit.hasInteractiveForm(doc),
           let rebuilt = PDFToolkit.dataStrippingHiddenMetadata(from: doc, applying: [:]) {
            return rebuilt
        }
        doc.documentAttributes = [:]
        return doc.dataRepresentation() ?? data
    }
}
