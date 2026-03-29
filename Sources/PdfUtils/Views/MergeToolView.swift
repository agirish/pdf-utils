import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct MergeEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct PreviewPage: Identifiable {
    var id: Int { number }
    let image: NSImage
    let number: Int
}

private struct MergeResult {
    let outputURL: URL
    let totalPages: Int
    let fileBytes: Int64
}

struct MergeToolView: View {
    @State private var entries: [MergeEntry] = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var selectedEntryID: UUID?
    @State private var isDropTargeted = false
    @State private var pagesByEntryID: [UUID: Int] = [:]
    @State private var totalPages = 0
    @State private var pageSummaryLoading = false

    @State private var previewPages: [PreviewPage] = []
    @State private var thumbnailSize: CGFloat = 120
    @State private var isGeneratingPreviews = false
    @State private var previewTask: Task<Void, Never>?

    @State private var mergeResult: MergeResult?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var entriesSignature: String {
        entries.map { "\($0.id.uuidString)|\($0.url.path)" }.joined(separator: "\u{1e}")
    }

    var body: some View {
        Group {
            if let result = mergeResult {
                successView(result)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarColumn
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
                } detail: {
                    previewDetailColumn
                }
            }
        }
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                appendUnique(urls)
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
        }
        .alert("pdf-utils", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: entriesSignature) {
            await refreshPageSummary()
        }
        .onChange(of: entries) { _, _ in
            generatePreviews()
        }
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { selectedEntryID = nil }
        }
    }

    // MARK: - Success

    private func successView(_ result: MergeResult) -> some View {
        ToolFormContainer {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                VStack(spacing: 8) {
                    Text("Merged successfully")
                        .font(.title2.weight(.bold))

                    Text(result.outputURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 32) {
                    StatBox(title: "SIZE", value: formatBytes(result.fileBytes))
                    StatBox(title: "PAGES", value: "\(result.totalPages)")
                    StatBox(title: "FILES", value: "\(entries.count)")
                }
                .padding(.top, 16)

                Button("Start over") {
                    withAnimation {
                        previewTask?.cancel()
                        entries.removeAll()
                        previewPages.removeAll()
                        pagesByEntryID = [:]
                        totalPages = 0
                        mergeResult = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 16)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                headerRow

                Group {
                    if entries.isEmpty {
                        emptyMergeDropZone
                    } else {
                        listCard
                    }
                }
                .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                    consumeDroppedProviders(providers)
                    return true
                }
            }
            .padding(18)
            .formCard()
            .padding([.horizontal, .top], 12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Merge & save…", busy: busy, canRun: !entries.isEmpty) {
                Task { await runMerge() }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF files")
                        .font(.subheadline.weight(.semibold))
                    Text(sidebarSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "square.stack.3d.up.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.merge.accent)
                    .font(.title2)
            }
            .labelStyle(.titleAndIcon)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                if !entries.isEmpty {
                    Button("Clear all") {
                        previewTask?.cancel()
                        entries.removeAll()
                        previewPages.removeAll()
                        pagesByEntryID = [:]
                        totalPages = 0
                        selectedEntryID = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove every file from the list")
                }
                Button("Add PDFs…") { showImporter = true }
            }
        }
    }

    private var emptyMergeDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.merge.accent.opacity(0.85))
            Text("Drop PDFs here or add files")
                .font(.headline.weight(.medium))
            Text("Files are combined top to bottom. Preview updates on the right.")
                .font(.subheadline)
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
                .foregroundStyle(isDropTargeted ? Tool.merge.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Merge list is empty. Drop PDF files or use choose PDFs.")
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if totalPages > 0 {
                Text("\(totalPages) pages across \(entries.count) files")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            List(selection: $selectedEntryID) {
                ForEach(entries) { entry in
                    mergeRow(for: entry)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
                        .listRowBackground(rowBackground)
                        .tag(Optional(entry.id))
                }
                .onMove(perform: moveEntries)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 160, idealHeight: 240, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .onDeleteCommand {
            deleteSelectedEntry()
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.025))
    }

    private func mergeRow(for entry: MergeEntry) -> some View {
        let index = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tool.merge.accent.opacity(0.14))
                    .frame(width: 36, height: 36)
                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Tool.merge.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.body)
                if let pages = pagesByEntryID[entry.id] {
                    Text("\(pages) page\(pages == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if pageSummaryLoading {
                    Text("Reading…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button {
                    moveEntry(from: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")

                Button {
                    moveEntry(from: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == entries.count - 1)
                .help("Move down")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            }

            Button(role: .destructive) {
                removeEntry(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from list")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(index + 1), \(entry.url.lastPathComponent)")
    }

    private var sidebarSubtitle: String {
        if entries.isEmpty {
            return "Add PDFs — order is top to bottom in the merged file. Preview appears on the right."
        }
        return "Drag more PDFs here to append. Reorder rows or use arrows; Delete removes the selection."
    }

    // MARK: - Preview (detail)

    private var previewDetailColumn: some View {
        Group {
            if !previewPages.isEmpty || isGeneratingPreviews {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preview")
                                .font(.subheadline.weight(.semibold))
                            Text("Visual order of the merged pages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isGeneratingPreviews {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Slider(value: $thumbnailSize, in: 60...240)
                                .frame(width: 140)
                        }
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 16)], spacing: 16) {
                            ForEach(previewPages) { page in
                                ZStack(alignment: .bottomTrailing) {
                                    Image(nsImage: page.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: thumbnailSize)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                                    Text("\(page.number)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Tool.merge.accent)
                                        .clipShape(Capsule())
                                        .padding(6)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("No PDFs selected for merge.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    // MARK: - Actions

    private func appendUnique(_ urls: [URL]) {
        let existing = Set(entries.map { $0.url.standardizedFileURL })
        let fresh = urls.filter { !existing.contains($0.standardizedFileURL) }
        entries.append(contentsOf: fresh.map { MergeEntry(url: $0) })
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            appendUnique(urls)
        }
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    private func moveEntry(from index: Int, by delta: Int) {
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    private func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries[index].id
        entries.remove(at: index)
        if selectedEntryID == removed {
            selectedEntryID = nil
        }
    }

    private func deleteSelectedEntry() {
        guard let id = selectedEntryID, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        removeEntry(at: idx)
    }

    private func refreshPageSummary() async {
        let snapshot = entries
        guard !snapshot.isEmpty else {
            await MainActor.run {
                pagesByEntryID = [:]
                totalPages = 0
                pageSummaryLoading = false
            }
            return
        }
        let urls = snapshot.map(\.url)
        await MainActor.run {
            pageSummaryLoading = true
            pagesByEntryID = [:]
            totalPages = 0
        }
        do {
            let counts = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(urls) {
                    var dict: [UUID: Int] = [:]
                    for e in snapshot {
                        dict[e.id] = PDFToolkit.pageCount(at: e.url) ?? 0
                    }
                    return dict
                }
            }
            await MainActor.run {
                pagesByEntryID = counts
                totalPages = counts.values.reduce(0, +)
                pageSummaryLoading = false
            }
        } catch {
            await MainActor.run {
                pagesByEntryID = [:]
                totalPages = 0
                pageSummaryLoading = false
            }
        }
    }

    private func generatePreviews() {
        previewTask?.cancel()
        guard !entries.isEmpty else {
            previewPages = []
            isGeneratingPreviews = false
            return
        }

        isGeneratingPreviews = true
        let urlsSnapshot = entries.map(\.url)

        previewTask = Task {
            do {
                let loadedPages: [PreviewPage] = try await PDFBackgroundWork.run {
                    var bgPreviews: [PreviewPage] = []
                    var globalPageNum = 1
                    try URLCollectionSecurityScope.withAccess(urlsSnapshot) {
                        for url in urlsSnapshot {
                            try Task.checkCancellation()
                            guard let doc = PDFDocument(url: url) else { continue }
                            for i in 0..<doc.pageCount {
                                try Task.checkCancellation()
                                guard let page = doc.page(at: i) else { continue }

                                let size = page.bounds(for: .mediaBox).size
                                let longest = max(size.width, size.height)
                                let scale = min(1.0, 400.0 / longest)
                                let thumbSize = NSSize(
                                    width: max(1, size.width * scale),
                                    height: max(1, size.height * scale)
                                )

                                let image = page.thumbnail(of: thumbSize, for: .mediaBox)
                                bgPreviews.append(PreviewPage(image: image, number: globalPageNum))
                                globalPageNum += 1
                            }
                        }
                    }
                    return bgPreviews
                }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    previewPages = loadedPages
                    isGeneratingPreviews = false
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        isGeneratingPreviews = false
                    }
                }
            }
        }
    }

    @MainActor
    private func runMerge() async {
        guard !entries.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        if let first = entries.first?.url {
            panel.nameFieldStringValue = first.deletingPathExtension().lastPathComponent + "-merged.pdf"
        } else {
            panel.nameFieldStringValue = "merged.pdf"
        }

        guard panel.runModal() == .OK, let outputURL = panel.url else {
            return
        }

        busy = true
        AppStateManager.shared.beginOperation("Merge PDF")
        defer {
            busy = false
            AppStateManager.shared.endOperation("Merge PDF")
        }

        let urlsSnapshot = entries.map(\.url)

        do {
            try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(urlsSnapshot) {
                    try PDFToolkit.merge(inputURLs: urlsSnapshot, outputURL: outputURL)
                }
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let bytes = attrs[.size] as? Int64 ?? 0

            let finalPages = try await PDFBackgroundWork.run {
                PDFToolkit.pageCount(at: outputURL) ?? 0
            }

            withAnimation {
                mergeResult = MergeResult(outputURL: outputURL, totalPages: finalPages, fileBytes: bytes)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Drop helpers

/// Isolate `loadItem` async helpers on the main actor so `NSItemProvider` is not sent across executors
/// when SwiftUI’s drop handler resumes (providers are not `Sendable`).
@MainActor
private extension NSItemProvider {
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

// MARK: - Success stats

private struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3.weight(.medium))
        }
        .frame(minWidth: 80)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}
