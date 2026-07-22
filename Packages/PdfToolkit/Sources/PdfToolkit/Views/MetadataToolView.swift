import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    /// The fields as loaded from the file — the baseline Reset returns to.
    @State private var loadedFields = PDFMetadataFields()
    /// The fields as currently edited.
    @State private var fields = PDFMetadataFields()
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "cleaned.pdf"
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            SinglePDFPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Pages in the file whose info you’re editing. Cleaning never changes them.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to see what it says about itself.",
                emptySystemImage: "tag.slash",
                render: { spec in
                    guard let url = inputURL else { return nil }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: spec.id - 1))?.image
                }
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                inputURL = urls.first
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.metadata.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.metadata.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await loadFile()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        FileSidebarHeader(
                            accent: accent,
                            icon: "tag.slash",
                            subtitle: inputURL == nil
                                ? "Drop a PDF or add a file to see its info fields."
                                : "Edit any field below, or strip everything in one go. The result is written to a new file.",
                            hasFile: inputURL != nil,
                            onClear: { inputURL = nil },
                            onAdd: { showImporter = true }
                        )

                        Group {
                            if inputURL == nil {
                                EmptyFileDropZone(
                                    accent: accent,
                                    icon: "tag.slash",
                                    description: "Title, author, keywords, the app that made it, dates—see it all, then edit or strip it.",
                                    isTargeted: isDropTargeted,
                                    onChoose: { showImporter = true }
                                )
                            } else if let url = inputURL {
                                SelectedFileCard(
                                    accent: accent,
                                    url: url,
                                    isLoadingPreview: isGeneratingPreviews,
                                    pageCount: pageSpecs.count
                                )
                            }
                        }
                        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }
                    }
                    .padding(18)
                    .formCard()

                    if let saveSummary {
                        ToolSaveBanner(accent: accent, summary: saveSummary)
                    }

                    if inputURL != nil {
                        fieldsSection
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Clean & save…", busy: busy, canRun: inputURL != nil) {
                Task { await runClean() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Info fields")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if fields != loadedFields {
                    Button("Reset") {
                        fields = loadedFields
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Restore the fields as they were loaded from the file")
                }
                Button("Strip All Fields") {
                    var cleared = PDFMetadataFields.cleared
                    cleared.producer = fields.producer
                    cleared.creationDate = fields.creationDate
                    cleared.modificationDate = fields.modificationDate
                    fields = cleared
                }
                .font(.subheadline.weight(.medium))
                .help("Blank every editable field")
            }

            fieldRow("Title", text: $fields.title)
            fieldRow("Author", text: $fields.author)
            fieldRow("Subject", text: $fields.subject)
            fieldRow("Keywords", text: $fields.keywords, prompt: "comma, separated")
            fieldRow("Creator app", text: $fields.creator)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                readOnlyRow("Producer", value: fields.producer.isEmpty ? "—" : fields.producer)
                readOnlyRow("Created", value: formatted(fields.creationDate))
                readOnlyRow("Modified", value: formatted(fields.modificationDate))
                Text("These three are set by macOS when you save: the Producer becomes the system PDF writer and both dates reset to the save time—so the original tool name and timestamps never travel with the cleaned file.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    private func fieldRow(_ label: String, text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt ?? "—"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func readOnlyRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func formatted(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
    }

    private var summaryLine: String {
        if fields.isCleared {
            return "Every editable field is cleared—the saved file will carry none of them."
        }
        let named = [
            (fields.author, "an author"),
            (fields.creator, "the creator app"),
        ].filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if named.isEmpty {
            return "No editable field identifies you or your tools."
        }
        return "This file still names \(named.map(\.1).joined(separator: " and "))."
    }

    /// The confirmation copy for a finished run, from a snapshot of the saved fields so it reflects
    /// what was written (not whatever the fields hold by the time a dialog returns).
    private func summaryText(for saved: PDFMetadataFields) -> (title: String, detail: String) {
        saved.isCleared
            ? ("Metadata stripped", "Every editable field was removed; the app name and dates were reset.")
            : ("Metadata cleaned", "The saved copy carries your edits; the app name and dates were reset.")
    }

    // MARK: - Loading

    private func loadFile() async {
        // A different (or removed) file: the last run's confirmation no longer describes what's loaded.
        saveSummary = nil
        guard let url = inputURL else {
            pageSpecs = []
            isGeneratingPreviews = false
            loadedFields = PDFMetadataFields()
            fields = PDFMetadataFields()
            return
        }
        pageSpecs = []
        isGeneratingPreviews = true
        do {
            let read = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess { try PDFToolkit.readMetadata(inputURL: url) }
            }
            guard !Task.isCancelled else { return }
            loadedFields = read
            fields = read
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            isGeneratingPreviews = false
            alertMessage = error.localizedDescription
            inputURL = nil
            return
        }
        do {
            // Only the page count loads up front; cells render on demand as they appear.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            guard !Task.isCancelled else { return }
            pageSpecs = PreviewPageSpec.specs(forPDFAt: url, pageCount: count)
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pageSpecs = []
            isGeneratingPreviews = false
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            if let url = await NSItemProvider.firstResolvablePDFURL(from: providers) {
                inputURL = url
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runClean() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        saveSummary = nil
        AppStateManager.shared.beginOperation(Tool.metadata.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.metadata.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-cleaned.pdf"
        let snapshot = fields
        let summary = summaryText(for: snapshot)

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.writeMetadataData(inputURL: fileURL, fields: snapshot)
                }
            }
            // applyMetadataStrip: false — the output IS deliberately chosen metadata; the global
            // "Strip metadata on export" setting must not erase what the user just typed.
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.metadata.title,
                defaultStem: "cleaned",
                suffixWord: "cleaned",
                applyMetadataStrip: false
            ) {
            case .savedBeside(let url):
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: nil)
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.metadata.title) failed: \(error.localizedDescription)")
        }
    }
}
