import SwiftUI
import UniformTypeIdentifiers

private struct MergeEntry: Identifiable {
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: (suggestedName as NSString).deletingPathExtension
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

        busy = true
        defer { busy = false }

        let urlsSnapshot = entries.map(\.url)
        suggestedName = "merged.pdf"

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
