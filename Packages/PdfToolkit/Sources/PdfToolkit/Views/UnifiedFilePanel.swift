import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// One file panel that adapts to how many files are in it, replacing the old "One file | Multiple
/// files" toggle. The count drives everything:
///
/// - **0 files** — an empty drop zone and preview.
/// - **1 file** — its pages preview on the right; the action saves it through the tool's own
///   single-file path (`runSingle`), so tool-specific niceties like Rotate's page range survive.
/// - **2+ files** — a progress queue; the action runs the shared `BatchOperation` across every file.
///
/// Output for a many-file run follows the Files → Save location setting: "Save beside original" writes
/// each result next to its own source (no prompt), "Ask each time" prompts once for a destination
/// folder. The single-file case already routes through `PDFExportCoordinator`, so it honors the same
/// setting via the host's `runSingle`.
///
/// The host tool owns the `BatchRunner` (so the list survives navigation), the `busy` flag, its own
/// `fileExporter`/alert, and supplies its config cards plus `runSingle`/`makeOperation`.
struct UnifiedFilePanel<Config: View>: View {
    @ObservedObject var runner: BatchRunner
    let tool: Tool
    /// Title for the single-file action button (e.g. "Rotate & save…").
    let singleActionTitle: String
    /// Single-file busy flag, owned by the host (it also drives the host's save dialog).
    @Binding var busy: Bool
    /// The operation for a many-file run; `nil` when the config isn't valid yet (empty watermark text,
    /// blank target size) — which also disables the single-file action.
    let makeOperation: () -> BatchOperation?
    /// Suffix word shown in the output-name hint before an operation is buildable (e.g. "compressed").
    var fallbackSuffix: String
    /// Preview-column subtitle for the one-file case.
    var previewSubtitle: String
    /// When true, an encrypted (locked) one-file input shows a "Locked PDF" placeholder instead of a
    /// thumbnail preview it can't render — Protect's remove-password inputs are locked until unlocked.
    var previewLocksWhenEncrypted: Bool = false
    /// Runs the host's single-file save for the one loaded file. The host reads its own controls,
    /// produces the data, routes it through `PDFExportCoordinator`, and shows its save dialog on
    /// `.present`.
    let runSingle: (URL) async -> Void
    /// The tool's configuration cards, count-aware if it needs to be (Rotate swaps page-scope for an
    /// all-pages note once there's more than one file).
    @ViewBuilder var config: () -> Config

    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var alertMessage: String?
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    /// The one loaded file is encrypted and can't be previewed until unlocked (Protect only).
    @State private var previewLocked = false

    private var accent: Color { tool.accent }
    private var fileCount: Int { runner.items.count }
    private var firstURL: URL? { runner.items.first?.url }
    private var currentOperation: BatchOperation? { makeOperation() }

    /// Only the exactly-one-file case renders thumbnails; anything else keys the load off "".
    private var previewPathKey: String {
        fileCount == 1 ? (firstURL?.standardizedFileURL.path ?? "") : ""
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            rightPane
                .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .onDisappear {
            // Leaving mid-run keeps landing files headless with the Cancel control gone; stop cleanly.
            runner.cancel()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): runner.addURLs(urls)
            case .failure(let err): alertMessage = err.localizedDescription
            }
        }
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: previewPathKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow

                    Group {
                        if runner.isEmpty {
                            emptyDropZone
                        } else if fileCount == 1, let url = firstURL {
                            selectedFileCard(url: url)
                        } else {
                            filesListCard
                        }
                    }
                    .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                        consumeDroppedProviders(providers)
                        return true
                    }

                    config()
                        .disabled(runner.isRunning)
                }
                .padding(18)
                .formCard()
                .padding(12)
            }

            Divider()

            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: tool.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text(fileCount > 1 ? "PDF files" : "PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !runner.isEmpty {
                        Button(fileCount > 1 ? "Clear all" : "Clear") { runner.clear() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(runner.isRunning)
                            .help("Remove every file")
                    }
                    Button(runner.isEmpty ? "Add PDF…" : "Add PDFs…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(runner.isRunning)
                }
            }
            Text(sidebarSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarSubtitle: String {
        switch fileCount {
        case 0:
            return "Drop a PDF or add a file — add several to run this tool across the whole set at once."
        case 1:
            return "Its pages preview on the right. Add more files to run the same settings on all of them."
        default:
            return "The same settings run on every file, following your Save location. Originals are never changed."
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: tool.symbolName)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Drop several to run this tool on all of them at once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDF…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5]))
                .foregroundStyle(isDropTargeted ? accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or add a file.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if isGeneratingPreviews {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else if !thumbnails.isEmpty {
                    Text("\(thumbnails.count) page\(thumbnails.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected file \(url.lastPathComponent)")
    }

    private var filesListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(fileCount) files queued")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            List {
                ForEach(runner.items) { item in
                    fileRow(for: item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 130, idealHeight: 200, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private func fileRow(for item: BatchRunner.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "doc.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                runner.remove(item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(runner.isRunning)
            .help("Remove from the list")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.url.lastPathComponent)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        Group {
            if runner.isRunning {
                Button(role: .destructive) {
                    runner.cancel()
                } label: {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Cancel").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if fileCount >= 2 {
                RunActionButton(title: "Run on \(fileCount) files", canRun: currentOperation != nil) {
                    startMultiRun()
                }
            } else {
                RunActionButton(title: singleActionTitle, busy: busy, canRun: !runner.isEmpty && currentOperation != nil) {
                    guard let url = firstURL else { return }
                    Task { await runSingle(url) }
                }
            }
        }
        .padding(16)
        .toolActionBar()
    }

    private func startMultiRun() {
        guard let operation = currentOperation else { return }
        switch SaveLocation.current() {
        case .besideOriginal:
            runner.run(operation: operation, destination: .besideEachSource)
        case .askEachTime:
            if let directory = chooseOutputFolder() {
                runner.run(operation: operation, destination: .folder(directory))
            }
        }
    }

    private func chooseOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the \(fileCount) output files"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Right pane

    private var rightPane: some View {
        Group {
            if runner.isEmpty {
                EmptyStateView(
                    icon: tool.symbolName,
                    tint: accent,
                    title: "No PDF selected",
                    message: "Drop a PDF here or choose one to preview it. Add several to run this tool on all of them."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            } else if fileCount == 1, previewLocked {
                EmptyStateView(
                    icon: "lock.fill",
                    tint: accent,
                    title: "Locked PDF",
                    message: "This PDF is password-protected. Enter its password on the left, then remove it to preview and unlock the file."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            } else if fileCount == 1 {
                SinglePDFPreviewColumn(
                    thumbnails: thumbnails,
                    isGenerating: isGeneratingPreviews,
                    thumbnailSize: $thumbnailSize,
                    accent: accent,
                    previewSubtitle: previewSubtitle,
                    emptyTitle: "No PDF selected",
                    emptySubtitle: "Drop a PDF here or choose one to see its pages.",
                    emptySystemImage: tool.symbolName
                )
            } else {
                queueColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryHeader

            List {
                ForEach(runner.items) { item in
                    queueRow(for: item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .padding(18)
        .formCard()
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToolPreviewPaneBackground())
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.title3.weight(.semibold))
                Spacer()
                if runner.doneCount > 0 {
                    Button("Show in Finder") {
                        let files = runner.items.compactMap { item -> URL? in
                            if case .done(let url, _) = item.status { return url }
                            return nil
                        }
                        if files.isEmpty, let dir = runner.outputDirectory {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(files)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
            }

            ProgressView(value: runner.progressFraction)
                .tint(accent)

            Text(summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        parts.append("\(runner.doneCount) done")
        if runner.runningCount > 0 { parts.append("\(runner.runningCount) running") }
        parts.append("\(runner.pendingCount) waiting")
        if runner.failedCount > 0 { parts.append("\(runner.failedCount) failed") }
        var line = parts.joined(separator: " · ")
        let saved = runner.bytesSaved
        if saved > 0 {
            line += " — saved \(Self.formatBytes(saved))"
        }
        return line
    }

    private func queueRow(for item: BatchRunner.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon(for: item.status)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusPill(for: item)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.url.lastPathComponent), \(accessibilityStatus(for: item))")
    }

    @ViewBuilder
    private func statusIcon(for status: BatchRunner.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusPill(for item: BatchRunner.Item) -> some View {
        switch item.status {
        case .pending:
            pill("Waiting", color: .secondary)
        case .running:
            pill("Working…", color: accent)
        case .done(_, let outputBytes):
            pill(doneLabel(inputBytes: item.inputBytes, outputBytes: outputBytes), color: .green)
        case .failed:
            pill("Failed", color: .red)
        }
    }

    private func doneLabel(inputBytes: Int64?, outputBytes: Int64) -> String {
        if let inputBytes, inputBytes > outputBytes {
            return "−\(Self.formatBytes(inputBytes - outputBytes))"
        }
        return Self.formatBytes(outputBytes)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func accessibilityStatus(for item: BatchRunner.Item) -> String {
        switch item.status {
        case .pending: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Thumbnails & drops

    private func loadThumbnails() async {
        guard fileCount == 1, let url = firstURL else {
            thumbnails = []
            isGeneratingPreviews = false
            previewLocked = false
            return
        }
        thumbnails = []
        // An encrypted input can't be rendered until unlocked; show the locked placeholder instead of
        // a futile thumbnail load. The check runs on the serial PDF queue like every other PDFKit call.
        if previewLocksWhenEncrypted {
            let locked = (try? await PDFBackgroundWork.run {
                (try? url.withSecurityScopedAccess { PDFDocument(url: url)?.isLocked ?? false }) ?? false
            }) ?? false
            guard !Task.isCancelled else { return }
            if locked {
                previewLocked = true
                isGeneratingPreviews = false
                return
            }
        }
        previewLocked = false
        isGeneratingPreviews = true
        do {
            let loaded = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            guard !Task.isCancelled else { return }
            thumbnails = loaded
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-render; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            thumbnails = []
            isGeneratingPreviews = false
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        guard !runner.isRunning else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            runner.addURLs(urls)
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
