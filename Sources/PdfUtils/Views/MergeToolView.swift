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
                    if !entries.isEmpty {
                        EditButton()
                    }
                    Button("Add PDFs…") { showImporter = true }
                }

                if !entries.isEmpty {
                    List {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HStack {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                Text(entry.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .onMove { from, to in
                            entries.move(fromOffsets: from, toOffset: to)
                        }
                        .onDelete { offsets in
                            entries.remove(atOffsets: offsets)
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
            document: $exportDoc,
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
        return "\(entries.count) file(s) — use Edit to reorder or delete rows."
    }

    @MainActor
    private func runMerge() async {
        guard !entries.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        defer { busy = false }

        let urls = entries.map(\.url)
        var startedAccess: [URL] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                for u in startedAccess {
                    u.stopAccessingSecurityScopedResource()
                }
                alertMessage = "Could not access \(url.lastPathComponent)."
                return
            }
            startedAccess.append(url)
        }
        defer {
            for u in startedAccess {
                u.stopAccessingSecurityScopedResource()
            }
        }

        suggestedName = "merged.pdf"

        do {
            let data = try PDFExportSupport.data { out in
                try PDFToolkit.merge(inputURLs: urls, outputURL: out)
            }
            exportDoc = PDFFileDocument(data: data)
            showExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
