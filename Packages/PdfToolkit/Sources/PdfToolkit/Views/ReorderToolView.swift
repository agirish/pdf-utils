import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct ReorderItem: Identifiable, Equatable {
    /// Stable identity = the page's position in the original document (zero-based).
    let id: Int
    var originalIndex: Int { id }
    var pageNumber: Int { id + 1 }
    let image: NSImage

    static func == (lhs: ReorderItem, rhs: ReorderItem) -> Bool { lhs.id == rhs.id }
}

struct ReorderToolView: View {
    @State private var inputURL: URL?
    @State private var items: [ReorderItem] = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "reordered.pdf"
    @State private var isDropTargeted = false
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    @State private var selectedItemID: Int?

    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var isReordered: Bool {
        items.enumerated().contains { $0.offset != $0.element.originalIndex }
    }

    /// The right-hand preview, in the current arrangement, each labeled with its original page number.
    private var previewThumbnails: [PDFPageThumbnail] {
        items.map { PDFPageThumbnail(pageNumber: $0.pageNumber, image: $0.image) }
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 540)
            SinglePDFPreviewColumn(
                thumbnails: previewThumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: Tool.reorder.accent,
                previewSubtitle: "Pages in the new order (labels show each page's original number).",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to arrange its pages.",
                emptySystemImage: "arrow.up.arrow.down.square"
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
                ActivityLog.shared.recordSaved(Tool.reorder.title, to: url, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.reorder.title) failed: \(err.localizedDescription)")
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
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                headerRow

                Group {
                    if inputURL == nil {
                        emptyDropZone
                    } else {
                        pageListCard
                    }
                }
                .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                    consumeDroppedProviders(providers)
                    return true
                }
            }
            .padding(18)
            .formCard()
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Save reordered PDF…", busy: busy, canRun: !items.isEmpty) {
                Task { await runReorder() }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.square")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.reorder.accent)
                    .font(.title)
                Text("Pages")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil, isReordered {
                        Button("Reset") { resetOrder() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Restore the original page order")
                    }
                    if inputURL != nil {
                        Button("Clear") { inputURL = nil }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Remove the selected file")
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
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
        if inputURL == nil {
            return "Drop a PDF or add a file. Drag rows — or use the arrows — to set a new page order."
        }
        return "Drag rows to rearrange, or use ↑ / ↓. The preview on the right follows the new order."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.square")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.reorder.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Its pages appear as a list you can drag into any order.")
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
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5])
                )
                .foregroundStyle(isDropTargeted ? Tool.reorder.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private var pageListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isGeneratingPreviews && items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading pages…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                Text("\(items.count) page\(items.count == 1 ? "" : "s") — drag to reorder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                List(selection: $selectedItemID) {
                    ForEach(items) { item in
                        pageRow(for: item)
                            .listRowInsets(EdgeInsets(top: density.rowInsetVertical, leading: 12, bottom: density.rowInsetVertical, trailing: 8))
                            .listRowBackground(rowBackground)
                            .tag(item.id)
                    }
                    .onMove(perform: moveItems)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220, idealHeight: 320, maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.025))
    }

    private func pageRow(for item: ReorderItem) -> some View {
        let position = items.firstIndex(of: item) ?? 0
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tool.reorder.accent.opacity(0.14))
                    .frame(width: 30, height: 30)
                Text("\(position + 1)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Tool.reorder.accent)
            }
            .accessibilityHidden(true)

            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 44)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }

            Text("Page \(item.pageNumber)")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button { move(from: position, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(position == 0)
                .help("Move up")

                Button { move(from: position, by: 1) } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(position == items.count - 1)
                .help("Move down")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(position + 1), original page \(item.pageNumber)")
    }

    // MARK: - Ordering

    private func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    private func move(from index: Int, by delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    private func resetOrder() {
        items.sort { $0.originalIndex < $1.originalIndex }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            items = []
            isGeneratingPreviews = false
            return
        }
        isGeneratingPreviews = true
        defer { isGeneratingPreviews = false }
        do {
            let thumbs = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            items = thumbs.map { ReorderItem(id: $0.pageNumber - 1, image: $0.image) }
        } catch {
            items = []
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    inputURL = url
                    return
                }
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runReorder() async {
        guard let fileURL = inputURL, !items.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.reorder.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.reorder.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-reordered.pdf"
        let order = items.map(\.originalIndex)

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        try PDFToolkit.reorder(inputURL: fileURL, outputURL: out, order: order)
                    }
                }
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.reorder.title) failed: \(error.localizedDescription)")
        }
    }
}
