import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct MergeEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct MergeToolView: View {
    @State private var entries: [MergeEntry] = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "merged.pdf"
    @State private var selectedEntryID: UUID?
    @State private var isDropTargeted = false
    @State private var pagesByEntryID: [UUID: Int] = [:]
    @State private var totalPages = 0
    @State private var pageSummaryLoading = false

    private var entriesSignature: String {
        entries.map { "\($0.id.uuidString)|\($0.url.path)" }.joined(separator: "\u{1e}")
    }

    var body: some View {
        ToolFormContainer {
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

            RunActionButton(title: "Merge & save…", busy: busy, canRun: !entries.isEmpty) {
                Task { await runMerge() }
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: stem(suggestedName)
        ) { result in
            exportDoc = nil
            if case .failure(let err) = result { alertMessage = err.localizedDescription }
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
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { selectedEntryID = nil }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF files")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
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
                        entries.removeAll()
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
            Text("Files are combined top to bottom. You can reorder after adding.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDFs…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
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
            .frame(minHeight: 200, idealHeight: 280, maxHeight: 420)
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

    private var subtitle: String {
        if entries.isEmpty {
            return "Add two or more PDFs. Order is top to bottom. Drag files from Finder or use Add PDFs."
        }
        return "Drag more PDFs onto the list to append. Reorder with the arrows or by dragging rows; Delete removes the selection."
    }

    private func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private func appendUnique(_ urls: [URL]) {
        let existing = Set(entries.map { $0.url.standardizedFileURL })
        let fresh = urls.filter { !existing.contains($0.standardizedFileURL) }
        entries.append(contentsOf: fresh.map { MergeEntry(url: $0) })
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        // Resolve on the main actor so `[NSItemProvider]` is not sent across isolation (it is not `Sendable`).
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

    @MainActor
    private func runMerge() async {
        guard !entries.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        defer { busy = false }

        let urlsSnapshot = entries.map(\.url)
        if let first = entries.first?.url {
            suggestedName = first.deletingPathExtension().lastPathComponent + "-merged.pdf"
        } else {
            suggestedName = "merged.pdf"
        }

        do {
            let data = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(urlsSnapshot) {
                    try PDFExportSupport.data { out in
                        try PDFToolkit.merge(inputURLs: urlsSnapshot, outputURL: out)
                    }
                }
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
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
