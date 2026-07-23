import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct OCRToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    /// The pending "your output will lose X" warning and its acknowledgement.
    @StateObject private var fidelity = OutputFidelityGate()
    @State private var accurate = true
    @State private var skipPagesWithText = true
    /// Chosen recognition language as a BCP-47 code; empty means Automatic (Vision auto-detects).
    @State private var recognitionLanguage = ""
    @State private var busy = false
    @State private var progressPage = 0
    @State private var progressTotal = 0
    /// The in-flight run, kept so Cancel and leaving the screen can actually abort it — recognition
    /// holds the shared PDF serial queue, so an unabortable multi-minute run starves every other
    /// tool's previews.
    @State private var runTask: Task<Void, Never>?
    /// Bumped at every run start AND end. Progress callbacks hop to the main actor as unordered
    /// tasks; the generation check drops both stragglers from a finished run and out-of-order
    /// updates (paired with the monotonic page guard).
    @State private var progressGeneration = 0
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "searchable.pdf"
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?
    /// A neutral, non-error outcome: every page already had selectable text, so nothing needed
    /// recognition and no file was saved. Shown as an informational banner, never the error alert.
    @State private var infoMessage: String?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    /// (code, display name) for the languages Vision recognizes on this Mac at each accuracy level,
    /// sorted by display name. Computed once per process — the supported sets are fixed for the OS
    /// build. Two lists because Fast supports far fewer languages than Accurate, and offering a
    /// language the running level can't recognize makes recognition silently return nothing.
    private static func languageChoices(accurate: Bool) -> [(code: String, name: String)] {
        let locale = Locale.current
        return PDFToolkit.supportedOCRLanguages(accurate: accurate)
            .map { (code: $0, name: locale.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private static let accurateLanguageChoices = languageChoices(accurate: true)
    private static let fastLanguageChoices = languageChoices(accurate: false)

    /// The choices for the currently-selected accuracy level.
    private var languageChoices: [(code: String, name: String)] {
        accurate ? Self.accurateLanguageChoices : Self.fastLanguageChoices
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
                previewSubtitle: "Pages in the file about to be recognized. The images stay exactly as they are.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a scanned PDF here or choose one to make it searchable.",
                emptySystemImage: "text.viewfinder",
                render: { spec in
                    guard let url = inputURL else { return nil }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: spec.id - 1))?.image
                }
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // A dimming scrim only — it must NOT intercept clicks. A `Color` is hit-testable at any
            // opacity, so without this it sits above the sidebar's Cancel button and swallows every
            // press, leaving only "leave the screen" to cancel. Hit-testing off keeps Cancel reachable;
            // the file controls are frozen separately below so the previewed file can't be swapped
            // out from under an in-flight run.
            if busy {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.ocr.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.ocr.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
        }
        .toolErrorAlert($alertMessage)
        .onChange(of: accurate) { _, nowAccurate in
            // A different accuracy would produce a different file, so the last save's receipt no
            // longer describes what a run now yields.
            saveSummary = nil
            // Switching to Fast (which recognizes far fewer languages) must drop a now-unsupported
            // pick back to Automatic — otherwise recognition would silently return nothing for it.
            let available = nowAccurate ? Self.accurateLanguageChoices : Self.fastLanguageChoices
            if !recognitionLanguage.isEmpty, !available.contains(where: { $0.code == recognitionLanguage }) {
                recognitionLanguage = ""
            }
        }
        .onChange(of: recognitionLanguage) { _, _ in saveSummary = nil }
        .onChange(of: skipPagesWithText) { _, _ in saveSummary = nil }
        .task(id: selectionPathKey) {
            guard let url = inputURL else {
                fidelity.update(nil)
                return
            }
            await fidelity.refresh(urls: [url]) { urls in
                urls.first.flatMap(OutputFidelityWarning.interactiveForm(at:))
            }
        }
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
        // Leaving the screen must free the PDF serial queue, not let a multi-minute recognition
        // run finish for a result nobody will see.
        .onDisappear {
            runTask?.cancel()
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
                            icon: "text.viewfinder",
                            subtitle: inputURL == nil
                                ? "Drop a scanned PDF or add a file. Recognition runs entirely on this Mac."
                                : "Recognition reads every page image and hides real, selectable text behind it.",
                            hasFile: inputURL != nil,
                            onClear: { inputURL = nil },
                            onAdd: { showImporter = true }
                        )
                        // Now that the scrim no longer blocks clicks, freeze Add/Clear while a run is
                        // busy so the file can't be swapped mid-run — the run keeps its captured URL,
                        // but a swap would strand a save receipt describing a file no longer shown.
                        .disabled(busy)

                        Group {
                            if inputURL == nil {
                                EmptyFileDropZone(
                                    accent: accent,
                                    icon: "text.viewfinder",
                                    description: "Scans and photographed documents become searchable—select, copy, and ⌘F just start working.",
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
                    } else if let infoMessage {
                        ToolInfoBanner(accent: accent, title: "Already searchable", message: infoMessage)
                    }

                    if inputURL != nil {
                        recognitionSection
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            VStack(spacing: 12) {
                if let warning = fidelity.warning {
                    OutputFidelityNote(warning: warning, toolTitle: Tool.ocr.title)
                }
                RunActionButton(title: "Make searchable & save…", busy: busy, canRun: inputURL != nil) {
                    guard fidelity.shouldProceed() else { return }
                    runTask = Task { await runOCR() }
                }
            }
            .padding(16)
            .toolActionBar()
            .outputFidelityConfirmation(fidelity, toolTitle: Tool.ocr.title) {
                runTask = Task { await runOCR() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recognition controls

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !languageChoices.isEmpty {
                HStack {
                    Text("Language")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Picker("Language", selection: $recognitionLanguage) {
                        Text("Automatic").tag("")
                        Divider()
                        ForEach(languageChoices, id: \.code) { choice in
                            Text(choice.name).tag(choice.code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Recognize a specific language, or let Vision detect it automatically")
                }
            }
            HStack {
                Text("Accuracy")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Accuracy", selection: $accurate) {
                    Text("Fast").tag(false)
                    Text("Accurate").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Skip pages that already have text", isOn: $skipPagesWithText)
                .toggleStyle(.checkbox)
                .font(.subheadline)
            Text(skipPagesWithText
                 ? "Pages whose text already selects are copied through untouched—only true scans are recognized."
                 : "Every page is recognized, even ones with live text. That can stack a second text layer; leave the skip on unless a page's existing text is broken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if busy && progressTotal > 0 {
                Divider()
                ProgressView(value: Double(progressPage), total: Double(progressTotal))
                HStack {
                    Text("Recognizing text… page \(progressPage) of \(progressTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") {
                        runTask?.cancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        // A different (or removed) file: the last run's confirmation/notice no longer describes it.
        saveSummary = nil
        infoMessage = nil
        guard let url = inputURL else {
            pageSpecs = []
            isGeneratingPreviews = false
            return
        }
        pageSpecs = []
        isGeneratingPreviews = true
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
            if case PDFOperationError.encryptedInput = error {
                // Locked selection: actionable message + back to the empty state (Metadata's pattern).
                alertMessage = error.localizedDescription
                inputURL = nil
            }
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        // A drop is another way to swap the file; block it while a run is busy, matching the disabled
        // Add/Clear header.
        guard !busy else { return }
        Task { @MainActor in
            if let url = await NSItemProvider.firstResolvablePDFURL(from: providers) {
                inputURL = url
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runOCR() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        saveSummary = nil
        infoMessage = nil
        progressPage = 0
        progressTotal = 0
        progressGeneration += 1
        let generation = progressGeneration
        AppStateManager.shared.beginOperation(Tool.ocr.title)
        defer {
            busy = false
            progressTotal = 0
            // Invalidate straggler progress tasks still queued on the main actor — without this a
            // late hop could repaint a "page N of M" readout after the run already finished.
            progressGeneration += 1
            runTask = nil
            AppStateManager.shared.endOperation(Tool.ocr.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-searchable.pdf"
        let options = OCROptions(
            accurate: accurate,
            skipPagesWithText: skipPagesWithText,
            recognitionLanguages: recognitionLanguage.isEmpty ? [] : [recognitionLanguage]
        )

        do {
            let outcome: (data: Data, summary: OCRRunSummary) = try await PDFBackgroundWork.run { isCancelled in
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.ocrData(
                        inputURL: fileURL,
                        options: options,
                        progress: { page, total in
                            Task { @MainActor in
                                // Main-actor hops are not FIFO: drop out-of-order and
                                // after-the-run updates instead of painting them.
                                guard generation == progressGeneration, page > progressPage else { return }
                                progressPage = page
                                progressTotal = total
                            }
                        },
                        isCancelled: isCancelled
                    )
                }
            }
            // A Cancel that lands in the tail window — after recognition's last per-page cancel check
            // but before we act on the result — must record nothing: no info banner, no save, no log,
            // no Finder reveal. Abort here into the silent `CancellationError` catch below, exactly as a
            // cancel during recognition would.
            try Task.checkCancellation()
            // All pages skipped means the output would be a pointless rebuilt copy — say so and
            // save nothing instead of shipping a file that changed no behavior. This is a normal,
            // expected outcome (the file was already searchable), NOT a failure, so it goes to the
            // neutral info banner rather than the app-name error alert.
            if outcome.summary.recognizedPages == 0 {
                let pages = outcome.summary.skippedPages
                infoMessage = "All \(pages) page\(pages == 1 ? " already has" : "s already have") selectable text, so nothing needed recognition and no file was saved. Turn off “Skip pages that already have text” to recognize them anyway."
                return
            }
            let data = outcome.data
            let recognized = outcome.summary.recognizedPages
            let summary = ToolSaveSummary(
                title: "Recognized text on \(recognized) page\(recognized == 1 ? "" : "s")",
                detail: "Saved a searchable copy — select, copy, and ⌘F now work.",
                url: nil
            )
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.ocr.title,
                defaultStem: "searchable",
                suffixWord: "searchable"
            ) {
            case .savedBeside(let url):
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = summary
                showExporter = true
            }
        } catch is CancellationError {
            // Cancelled deliberately — the Cancel button or leaving the screen. Nothing to report.
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.ocr.title) failed: \(error.localizedDescription)")
        }
    }
}
