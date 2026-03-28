import SwiftUI
import UniformTypeIdentifiers
import PDFKit

private struct MergeEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct PreviewPage: Identifiable {
    let id = UUID()
    let image: NSImage
    let number: Int
}

struct MergeToolView: View {
    @State private var entries: [MergeEntry] = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false

    
    @State private var previewPages: [PreviewPage] = []
    @State private var thumbnailSize: CGFloat = 120
    @State private var isGeneratingPreviews = false
    @State private var previewTask: Task<Void, Never>? = nil

    var body: some View {
        ToolFormContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PDF files").font(.subheadline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add PDFs…") { showImporter = true }
                }

                if !entries.isEmpty {
                    List {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                Text(entry.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
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
                                Button(role: .destructive) {
                                    removeEntry(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from list")
                            }
                        }
                    }
                    .frame(minHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(16)
            .formCard()

            if !previewPages.isEmpty || isGeneratingPreviews {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preview").font(.subheadline.weight(.semibold))
                            Text("Visual order of the merged pages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isGeneratingPreviews {
                            ProgressView().controlSize(.small)
                        } else {
                            Slider(value: $thumbnailSize, in: 60...240)
                                .frame(width: 120)
                        }
                    }
                    
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHGrid(rows: [GridItem(.fixed(thumbnailSize))], spacing: 16) {
                            ForEach(previewPages) { page in
                                ZStack(alignment: .bottomTrailing) {
                                    Image(nsImage: page.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: thumbnailSize)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                                        
                                    Text("\(page.number)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor)
                                        .clipShape(Capsule())
                                        .padding(4)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                    .frame(height: thumbnailSize + 24)
                }
                .padding(16)
                .formCard()
            }

            RunActionButton(title: "Merge & save…", busy: busy) {
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
                entries.append(contentsOf: urls.map { MergeEntry(url: $0) })
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
        .onChange(of: entries) {
            generatePreviews()
        }
    }

    private var subtitle: String {
        if entries.isEmpty { return "None selected — order is top to bottom in the merged PDF." }
        return "\(entries.count) file(s) — use ↑ ↓ to reorder; trash removes a row from the merge list."
    }

    private func moveEntry(from index: Int, by delta: Int) {
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    private func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }

    @MainActor
    private func runMerge() async {
        guard !entries.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "merged.pdf"
        
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            return // User cancelled
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
        } catch {
            alertMessage = error.localizedDescription
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
                                let thumbSize = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
                                
                                let image = page.thumbnail(of: thumbSize, for: .mediaBox)
                                bgPreviews.append(PreviewPage(image: image, number: globalPageNum))
                                globalPageNum += 1
                            }
                        }
                    }
                    return bgPreviews
                }
                
                if !Task.isCancelled {
                    self.previewPages = loadedPages
                    self.isGeneratingPreviews = false
                }
            } catch {
                if !Task.isCancelled {
                    self.isGeneratingPreviews = false
                }
            }
        }
    }
}
