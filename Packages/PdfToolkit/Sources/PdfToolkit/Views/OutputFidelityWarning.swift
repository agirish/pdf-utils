import Foundation
import PDFKit
import SwiftUI

/// Something a tool's output will genuinely lose, detected from the loaded source file(s).
///
/// Two rebuild limits can't be engineered away, so they are disclosed instead of discovered:
///
/// - **Interactive form fields** — Watermark, OCR, Fill & Sign, Compress and Redact re-emit each
///   page through a `CGPDFContext`, which has no notion of an `/AcroForm`. A fillable field is
///   flattened into the page picture: it still *looks* right, but it can't be filled in again.
/// - **Bookmarks** — Merge concatenates pages from many documents (each with its own outline, at
///   shifting offsets, under per-file page selections) and Split cuts one outline across several
///   files. A correct combined or per-part outline is real work, and a naive reassign would point
///   bookmarks at the wrong pages, so both deliberately drop it (see the NOTE comments in
///   `PDFToolkit.mergeData` / `PDFToolkit.split`).
///
/// A warning is only ever built when the *loaded file actually has* the thing at risk, so it stays
/// meaningful rather than becoming permanent wallpaper. Everything else the rebuilds used to lose —
/// bookmarks, the document title, links — is now preserved (`PDFToolkit.restoringCatalog`), so it is
/// deliberately NOT listed here.
struct OutputFidelityWarning: Equatable {
    enum Kind: Equatable {
        case interactiveForm
        /// `total` bookmarks across `fileCount` source files.
        case bookmarks(total: Int, fileCount: Int)
    }

    var kind: Kind

    var symbolName: String {
        switch kind {
        case .interactiveForm: return "exclamationmark.triangle.fill"
        case .bookmarks: return "bookmark.slash.fill"
        }
    }

    /// The banner's bold first line.
    var headline: String {
        switch kind {
        case .interactiveForm:
            return "This PDF has fillable form fields"
        case .bookmarks:
            return "Bookmarks won’t carry over"
        }
    }

    /// The banner's body — states exactly what is lost and what is not.
    func detail(toolTitle: String) -> String {
        switch kind {
        case .interactiveForm:
            return "They’ll be flattened into the page — the saved copy looks identical but can no longer be filled in or edited. Bookmarks, links, and the title are kept."
        case .bookmarks(let total, let fileCount):
            let bookmarks = total == 1 ? "1 bookmark" : "\(total) bookmarks"
            let source = fileCount <= 1
                ? "This PDF has \(bookmarks)."
                : "\(fileCount) of these files have bookmarks (\(bookmarks) in total)."
            return "\(source) The \(toolTitle.lowercased()) output won’t have any — page content, links, and form fields are unaffected."
        }
    }

    /// Title of the confirmation the user must acknowledge before the file is written.
    var confirmationTitle: String {
        switch kind {
        case .interactiveForm: return "Form fields will be flattened"
        case .bookmarks: return "Bookmarks won’t carry over"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .interactiveForm: return "Flatten and continue"
        case .bookmarks: return "Continue without bookmarks"
        }
    }

    // MARK: Detection

    /// The form warning for a single loaded file, or nil when it carries no `/AcroForm`.
    ///
    /// Touches PDFKit, so call it off the main actor through ``PDFBackgroundWork``.
    static func interactiveForm(at url: URL) -> OutputFidelityWarning? {
        let hasForm = (try? url.withSecurityScopedAccess { PDFToolkit.hasInteractiveForm(at: url) }) ?? false
        return hasForm ? OutputFidelityWarning(kind: .interactiveForm) : nil
    }

    /// The bookmark warning for the queued sources, or nil when none of them has an outline.
    ///
    /// Touches PDFKit, so call it off the main actor through ``PDFBackgroundWork``.
    static func bookmarks(in urls: [URL]) -> OutputFidelityWarning? {
        var total = 0
        var files = 0
        for url in urls {
            let count = (try? url.withSecurityScopedAccess { PDFToolkit.bookmarkCount(at: url) }) ?? 0
            if count > 0 {
                total += count
                files += 1
            }
        }
        guard total > 0 else { return nil }
        return OutputFidelityWarning(kind: .bookmarks(total: total, fileCount: files))
    }
}

/// The amber advisory banner for an ``OutputFidelityWarning``.
///
/// Amber, not red: this is a real consequence the user should see, but the operation is still valid
/// and will run — the codebase reserves red for hard errors (see ``RangeFieldNote``).
struct OutputFidelityNote: View {
    let warning: OutputFidelityWarning
    let toolTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning.symbolName)
                .font(.caption)
                .foregroundStyle(Color.fieldWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.headline)
                    .font(.caption.weight(.medium))
                Text(warning.detail(toolTitle: toolTitle))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.fieldWarning)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.fieldWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: LiquidGlass.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius)
                .strokeBorder(Color.fieldWarning.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. \(warning.headline). \(warning.detail(toolTitle: toolTitle))")
    }
}

/// Tracks a tool's pending fidelity warning and whether the user has acknowledged it.
///
/// The acknowledgement is per-warning, not per-session: swapping in a different file re-arms the
/// confirmation, so a user who accepted flattening for one form can't have it silently applied to
/// the next document they load.
@MainActor
final class OutputFidelityGate: ObservableObject {
    @Published private(set) var warning: OutputFidelityWarning?
    @Published var isConfirming = false
    private var acknowledged: OutputFidelityWarning?

    /// Replaces the current warning. Clears the acknowledgement whenever the warning changes, so a
    /// newly loaded file must be confirmed on its own terms.
    func update(_ new: OutputFidelityWarning?) {
        guard new != warning else { return }
        warning = new
        acknowledged = nil
    }

    /// True when the caller may proceed straight to saving. When false, the confirmation is raised
    /// and the caller should return — the confirm action re-enters the save.
    func shouldProceed() -> Bool {
        guard let warning, acknowledged != warning else { return true }
        isConfirming = true
        return false
    }

    /// Records the user's acknowledgement so the re-entered save runs through.
    func acknowledge() {
        acknowledged = warning
        isConfirming = false
    }

    /// Re-detects the warning for `urls`. The detector opens PDFs, so it runs on the shared serial
    /// queue — never on the main actor, and never alongside other PDFKit work.
    func refresh(urls: [URL], detect: @escaping @Sendable ([URL]) -> OutputFidelityWarning?) async {
        guard !urls.isEmpty else {
            update(nil)
            return
        }
        let detected = try? await PDFBackgroundWork.run { detect(urls) }
        guard !Task.isCancelled else { return }
        update(detected ?? nil)
    }
}

extension View {
    /// The confirmation a fidelity warning must pass before a tool writes its output. `onConfirm`
    /// re-enters the same save action — the gate lets it through once acknowledged.
    func outputFidelityConfirmation(
        _ gate: OutputFidelityGate,
        toolTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(
            gate.warning?.confirmationTitle ?? "",
            isPresented: Binding(get: { gate.isConfirming }, set: { gate.isConfirming = $0 }),
            presenting: gate.warning
        ) { warning in
            Button(warning.confirmButtonTitle) {
                gate.acknowledge()
                onConfirm()
            }
            Button("Cancel", role: .cancel) { gate.isConfirming = false }
        } message: { warning in
            Text(warning.detail(toolTitle: toolTitle))
        }
    }
}
