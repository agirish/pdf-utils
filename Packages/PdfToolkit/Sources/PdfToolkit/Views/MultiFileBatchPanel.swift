import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Whether a batch-capable tool is working on a single file (its default, unchanged flow) or a whole
/// list of files. Drives the segmented "One file | Multiple files" toggle at the top of each tool.
enum ToolFileMode: String, CaseIterable, Identifiable {
    case single
    case multiple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "One file"
        case .multiple: return "Multiple files"
        }
    }
}

/// The segmented mode toggle each batch-capable tool shows near the top of its sidebar. A tiny shared
/// view so the four tools present the switch identically.
struct ToolFileModePicker: View {
    @Binding var mode: ToolFileMode

    var body: some View {
        Picker("Files", selection: $mode) {
            ForEach(ToolFileMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// The whole "Multiple files" experience, shared by every batch-capable tool (Compress, Rotate,
/// Watermark, Protect). It owns the input-files list (add/drop/remove), the output-folder picker, the
/// Run/Cancel action bar, and the per-file progress queue — everything that used to live in the
/// standalone Batch tool. The host tool supplies its own config controls through `config`, and a
/// `makeOperation` closure that snapshots those controls into a `BatchOperation` at Run time. The
/// `BatchRunner` is owned by the host so the queue survives a mode flip.
struct MultiFileBatchPanel<Config: View>: View {
    @ObservedObject var runner: BatchRunner
    /// The host tool, for its accent, SF Symbol, and queue title.
    let tool: Tool
    /// The mode toggle, rendered at the top of the sidebar so the switch back to one-file is always in
    /// reach.
    @Binding var mode: ToolFileMode
    /// Snapshots the tool's live config into the operation to run, or nil when the controls aren't
    /// valid yet (empty watermark text, mismatched passwords, …) — the Run button stays disabled then.
    let makeOperation: () -> BatchOperation?
    /// Filename suffix shown in the output hint before an operation is buildable (e.g. "compressed").
    var fallbackSuffix: String
    /// The tool's own configuration cards, reused verbatim from its single-file mode.
    @ViewBuilder var config: () -> Config

    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var alertMessage: String?
    @State private var outputDirectory: URL?

    private var accent: Color { tool.accent }

    private var currentOperation: BatchOperation? { makeOperation() }

    private var canRun: Bool {
        !runner.isEmpty && outputDirectory != nil && currentOperation != nil && !runner.isRunning
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
            queueColumn
                .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                runner.addURLs(urls)
            case .failure(let err):
                alertMessage = err.localizedDescription
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
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ToolFileModePicker(mode: $mode)

                    headerRow

                    Group {
                        if runner.isEmpty {
                            emptyDropZone
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

                    outputCard
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
                Text("PDF files")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !runner.isEmpty {
                        Button("Clear all") { runner.clear() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(runner.isRunning)
                            .help("Remove every file from the queue")
                    }
                    Button("Add PDFs…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(runner.isRunning)
                }
            }
            Text(runner.isEmpty
                 ? "Drop several PDFs or add files, then run this tool across the whole set."
                 : "The same settings run on every file into your output folder. Originals are never changed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: tool.symbolName)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop PDFs here or add files")
                .font(.title3.weight(.semibold))
            Text("Every file is processed with the same settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDFs…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5])
                )
                .foregroundStyle(isDropTargeted ? accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queue is empty. Drop PDF files or choose PDFs.")
    }

    private var filesListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(runner.items.count) file\(runner.items.count == 1 ? "" : "s") queued")
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
            .help("Remove from the queue")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.url.lastPathComponent)
    }

    // MARK: - Output folder

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output folder")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(accent)
                if let dir = outputDirectory {
                    Text(dir.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No folder chosen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(outputDirectory == nil ? "Choose…" : "Change…") { chooseOutputFolder() }
                    .disabled(runner.isRunning)
            }
            Text("Results are written here, named like the single tools (name-\(currentOperation?.suffixWord ?? fallbackSuffix).pdf). Existing files are numbered, never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
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
            } else {
                RunActionButton(title: runButtonTitle, canRun: canRun) {
                    startRun()
                }
            }
        }
        .padding(16)
        .toolActionBar()
    }

    private var runButtonTitle: String {
        let n = runner.items.count
        return n == 1 ? "Run on 1 file" : "Run on \(n) files"
    }

    // MARK: - Queue (main area)

    private var queueColumn: some View {
        VStack(spacing: 0) {
            if runner.isEmpty {
                EmptyStateView(
                    icon: tool.symbolName,
                    tint: accent,
                    title: "No files queued",
                    message: "Add PDFs on the left, choose an output folder, then run to watch per-file progress here."
                )
            } else {
                queueContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToolPreviewPaneBackground())
    }

    private var queueContent: some View {
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
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.title3.weight(.semibold))
                Spacer()
                if runner.doneCount > 0, let dir = runner.outputDirectory {
                    Button("Show in Finder") {
                        let files = runner.items.compactMap { item -> URL? in
                            if case .done(let url, _) = item.status { return url }
                            return nil
                        }
                        if files.isEmpty {
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
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
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
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    private func accessibilityStatus(for item: BatchRunner.Item) -> String {
        switch item.status {
        case .pending: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard let directory = outputDirectory, let operation = currentOperation else { return }
        runner.run(operation: operation, into: directory)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the batch output"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
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

    // MARK: - Formatting

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
