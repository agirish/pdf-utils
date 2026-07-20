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
        let filename = suggestedFilename(stem: stem, suffixWord: suffixWord)

        guard SaveLocation.current() == .besideOriginal, let source else {
            return .present(document: PDFFileDocument(data: finalized), suggestedName: filename)
        }

        let directory = source.deletingLastPathComponent()
        let destination = uniqueURL(inDirectory: directory, filename: filename)
        try await PDFBackgroundWork.run { try finalized.write(to: destination, options: .atomic) }
        ActivityLog.shared.recordSaved(toolTitle, to: destination, bytes: finalized.count)
        AfterExportAction.current().perform(on: [destination])
        return .savedBeside(destination)
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

    /// Returns `data` with its document info dictionary (author, title, creator, dates, keywords)
    /// cleared. Fail-safe: any parse/serialize failure returns the input unchanged rather than losing
    /// the export.
    ///
    /// Encrypted output (the Protect tool's password mode) is returned untouched: re-serializing a
    /// locked/encrypted `PDFDocument` would drop or corrupt its encryption, which matters far more
    /// than clearing its info dictionary.
    static func stripMetadata(_ data: Data) -> Data {
        guard let doc = PDFDocument(data: data), !doc.isEncrypted, !doc.isLocked else { return data }
        doc.documentAttributes = [:]
        return doc.dataRepresentation() ?? data
    }
}
