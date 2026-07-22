import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum SignatureMode: Hashable {
    case draw
    case type
}

struct FillSignToolView: View {
    @State private var inputURL: URL?
    @State private var pdfDocument: PDFDocument?
    @State private var items: [FillSignItem] = []
    @State private var selectedID: UUID?
    @State private var currentPageIndex = 0
    /// ⌘Z / ⌘⇧Z history over the whole item set — placement, move, resize, nudge, delete, edits, Clear.
    @State private var undo = UndoHistory<[FillSignItem]>([])
    /// True while a canvas drag is in flight, so the whole drag collapses to one undo step.
    @State private var canvasInteracting = false
    /// True while the font-size slider is being dragged, so a slider sweep is one undo step, not dozens.
    @State private var fontSliderEditing = false
    /// Bridge to the editor's live viewport, so a new item lands where the user is looking.
    @State private var placement = FillSignPlacement()
    /// Advances on each add so successive items fan out instead of stacking; reset on a new page or file.
    @State private var placementCascade = 0

    @State private var inkID = "black"
    @State private var newFontSize: CGFloat = 14

    @State private var signatureMode: SignatureMode = .draw
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var signatureAspect: CGFloat = 2.3
    @State private var typedSignature = ""

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "filled.pdf"
    @State private var isDropTargeted = false

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?

    @FocusState private var textFieldFocused: Bool

    @Environment(\.toolAccent) private var accent

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    /// While any of these is true the user is mid-edit, so undo snapshots are deferred and the whole
    /// gesture (a canvas drag, a slider sweep, or a typing session in the inspector field) collapses to
    /// a single undo step captured when it settles.
    private var editingContinuously: Bool {
        canvasInteracting || fontSliderEditing || textFieldFocused
    }

    private var selectedInk: InkColor {
        InkColor.with(id: inkID)
    }

    private var canRun: Bool {
        inputURL != nil && pdfDocument != nil && items.contains(where: \.hasInk)
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth(.compact)
            editorPane
                .frame(minWidth: 480)
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.fillSign.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.fillSign.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await reloadDocumentForSelection()
        }
        // Record each settled change to the items as one undo step, but never the intermediate frames
        // of a live drag / slider sweep / typing session (editingContinuously gates those; each ends
        // by committing its settled value below). A commit equal to the current snapshot is a no-op, so
        // the re-commit that fires when undo/redo reassigns `items` records nothing.
        .onChange(of: items) { _, newItems in
            if !editingContinuously { undo.commit(newItems) }
        }
        .onChange(of: editingContinuously) { _, active in
            if !active { undo.commit(items) }
        }
    }

    private func performUndo() {
        guard let restored = undo.undo() else { return }
        items = restored
        if let sel = selectedID, !items.contains(where: { $0.id == sel }) { selectedID = nil }
    }

    private func performRedo() {
        guard let restored = undo.redo() else { return }
        items = restored
        if let sel = selectedID, !items.contains(where: { $0.id == sel }) { selectedID = nil }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        headerRow

                        Group {
                            if inputURL == nil {
                                emptyDropZone
                            } else if let url = inputURL {
                                selectedFileCard(url: url)
                            }
                        }
                        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }

                        if pdfDocument != nil {
                            addContentSection
                            signatureSection
                            if let id = selectedID, items.contains(where: { $0.id == id }) {
                                selectedItemInspector(id: id)
                            }
                            if !items.isEmpty {
                                itemsSection
                            }
                        }
                    }
                    .padding(18)
                    .formCard()

                    if let saveSummary {
                        ToolSaveBanner(accent: accent, summary: saveSummary)
                    }
                }
                .padding(12)
            }

            Divider()

            RunActionButton(title: "Sign & save…", busy: busy, canRun: canRun) {
                Task { await runFillSign() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: Tool.fillSign.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") {
                            inputURL = nil
                            pdfDocument = nil
                            items = []
                            selectedID = nil
                            undo.reset([])
                            placementCascade = 0
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                }
            }
            Text(inputURL == nil
                 ? "Add a flat PDF form, then drop typed text and a signature onto the page."
                 : "Add text and a signature on the page, then save. The original file is unchanged.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: Tool.fillSign.symbolName)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Fill in a non-interactive form and sign it — everything stays on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if let doc = pdfDocument {
                    Text("\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s") · \(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
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
    }

    // MARK: Add text / date

    private var addContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to page \(currentPageDisplayNumber)")
                .font(.subheadline.weight(.semibold))

            inkPalette

            HStack(spacing: 10) {
                Button {
                    addTextItem(string: "")
                } label: {
                    Label("Add text", systemImage: "textformat")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    addTextItem(string: Self.todayString())
                } label: {
                    Label("Add date", systemImage: "calendar")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("New items appear in the visible area of the page and fan out as you add more. Drag to position; drag the corner to resize.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    private var inkPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ink color")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(InkColor.palette) { ink in
                    Button {
                        inkID = ink.id
                    } label: {
                        Circle()
                            .fill(ink.color)
                            .frame(width: InkColor.swatchDiameter, height: InkColor.swatchDiameter)
                            .overlay {
                                Circle().strokeBorder(
                                    inkID == ink.id ? Color.primary.opacity(0.5) : .clear,
                                    lineWidth: 2.5
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(ink.name)
                }
            }
        }
    }

    // MARK: Signature

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signature")
                .font(.subheadline.weight(.semibold))

            Picker("Signature style", selection: $signatureMode) {
                Text("Draw").tag(SignatureMode.draw)
                Text("Type").tag(SignatureMode.type)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if signatureMode == .draw {
                SignatureCanvas(strokes: $signatureStrokes, aspect: $signatureAspect, inkColor: selectedInk.color)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Button("Clear") { signatureStrokes = [] }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(signatureStrokes.allSatisfy(\.isEmpty))
                    Spacer()
                    Button("Place signature") { placeDrawnSignature() }
                        .buttonStyle(.bordered)
                        .disabled(signatureStrokes.allSatisfy(\.isEmpty))
                }
            } else {
                TextField("Type your name", text: $typedSignature)
                    .textFieldStyle(.roundedBorder)
                Text(typedSignature.isEmpty ? "Your name in a handwriting font." : typedSignature)
                    .font(.custom("SnellRoundhand", size: 30))
                    .foregroundStyle(typedSignature.isEmpty ? Color.secondary : selectedInk.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                HStack {
                    Spacer()
                    Button("Place signature") { placeTypedSignature() }
                        .buttonStyle(.bordered)
                        .disabled(typedSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: Selected item inspector

    @ViewBuilder
    private func selectedItemInspector(id: UUID) -> some View {
        if let index = items.firstIndex(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Selected item")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(role: .destructive) {
                        items.removeAll { $0.id == id }
                        selectedID = nil
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(accent)
                }

                switch items[index].content {
                case .text:
                    TextField("Type here…", text: textBinding(id: id), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($textFieldFocused)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Font size")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(fontSizeBinding(id: id).wrappedValue)) pt")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: fontSizeBinding(id: id), in: 8...48) { editing in
                            // Coalesce the whole slider sweep into one undo step.
                            fontSliderEditing = editing
                        }
                    }
                case .signature:
                    Text("Drag the signature to position it, or drag its corner handle to resize. It scales as vector ink.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .formCard()
        }
    }

    // MARK: Items list

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Items (\(items.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear all") {
                    items = []
                    selectedID = nil
                    placementCascade = 0
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            }
            ForEach(items) { item in
                Button {
                    selectedID = item.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isText ? "textformat" : "signature")
                            .foregroundStyle(accent)
                            .frame(width: 18)
                        Text(itemLabel(item))
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("Page \(item.pageIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            items.removeAll { $0.id == item.id }
                            if selectedID == item.id { selectedID = nil }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this item")
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedID == item.id ? accent.opacity(0.14) : Color.primary.opacity(0.03))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .formCard()
    }

    private func itemLabel(_ item: FillSignItem) -> String {
        switch item.content {
        case .text(let t):
            let trimmed = t.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Empty text" }
            return t.isScript ? "✍︎ \(trimmed)" : trimmed
        case .signature:
            return "Signature"
        }
    }

    // MARK: - Editor pane

    private var editorPane: some View {
        Group {
            if let doc = pdfDocument {
                VStack(spacing: 0) {
                    editorToolbar
                    Divider().opacity(0.35)
                    FillSignPDFEditor(
                        document: doc,
                        items: $items,
                        selectedID: $selectedID,
                        currentPageIndex: $currentPageIndex,
                        placement: placement,
                        accent: accent,
                        isInteracting: $canvasInteracting,
                        onUndo: performUndo,
                        onRedo: performRedo
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .onChange(of: currentPageIndex) { _, _ in
                        // A fresh page starts the cascade over, so items don't inherit an off-page offset.
                        placementCascade = 0
                    }
                }
            } else if inputURL != nil {
                ProgressView("Opening PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                EmptyStateView(
                    icon: "hand.draw",
                    title: "No PDF selected",
                    message: "Choose a file, then add text and a signature onto the page."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    /// A thin bar above the canvas: Undo/Redo (the mouse path to the same history ⌘Z reaches) and a
    /// one-line reminder of the direct-manipulation gestures.
    private var editorToolbar: some View {
        HStack(spacing: 10) {
            EditorUndoButtons(canUndo: undo.canUndo, canRedo: undo.canRedo, accent: accent, undo: performUndo, redo: performRedo)
            Spacer(minLength: 8)
            Text("drag to move · handle to resize · arrows to nudge · delete to remove · ⌘Z to undo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Placement

    private var currentPageDisplayNumber: Int { clampedPageIndex() + 1 }

    private func clampedPageIndex() -> Int {
        guard let doc = pdfDocument, doc.pageCount > 0 else { return 0 }
        return min(max(currentPageIndex, 0), doc.pageCount - 1)
    }

    private func pageBox(_ index: Int) -> CGRect? {
        guard let doc = pdfDocument, index >= 0, index < doc.pageCount,
              let page = doc.page(at: index) else { return nil }
        return page.bounds(for: .cropBox)
    }

    /// The rect a newly-placed item of `size` should occupy on `pageIndex`: centered on the visible
    /// part of the page (so it lands in view even when the page is scrolled), nudged by a per-add
    /// cascade so repeated adds fan out instead of stacking, then clamped inside the page. Advances
    /// the cascade. The center falls back to the page's geometric center before the editor is mounted.
    private func placementRect(size: CGSize, in box: CGRect, pageIndex: Int) -> CGRect {
        let center = placement.visibleCenter?(pageIndex) ?? CGPoint(x: box.midX, y: box.midY)
        let rect = FillSignGeometry.placedRect(center: center, size: size, cascade: placementCascade, in: box)
        placementCascade += 1
        return rect
    }

    private func addTextItem(string: String) {
        let index = clampedPageIndex()
        guard let box = pageBox(index) else { return }
        let width = min(max(box.width * 0.45, 120), box.width - 20)
        let height = max(newFontSize * 1.8, 26)
        let rect = placementRect(size: CGSize(width: width, height: height), in: box, pageIndex: index)
        let ink = selectedInk
        let item = FillSignItem(
            pageIndex: index,
            rect: rect,
            content: .text(FillSignText(
                string: string,
                fontSize: newFontSize,
                red: ink.red,
                green: ink.green,
                blue: ink.blue
            ))
        )
        items.append(item)
        selectedID = item.id
        // Focus on the NEXT runloop turn, not synchronously: the inspector text field is gated on
        // selectedID and isn't in the hierarchy yet, so a synchronous @FocusState request is unreliable
        // — and it would gate THIS add's undo commit behind the field's focus (editingContinuously),
        // greying Undo on a placed item and making add-then-Clear non-undoable. Deferring lets the add
        // commit as its own step first, then focuses the now-rendered field for typing.
        DispatchQueue.main.async { textFieldFocused = true }
    }

    private func placeDrawnSignature() {
        let strokes = signatureStrokes.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { return }
        let index = clampedPageIndex()
        guard let box = pageBox(index) else { return }
        let aspect = max(signatureAspect, 0.2)
        let width = min(max(box.width * 0.4, 140), box.width - 20)
        let height = max(width / aspect, 30)
        let rect = placementRect(size: CGSize(width: width, height: height), in: box, pageIndex: index)
        let ink = selectedInk
        let item = FillSignItem(
            pageIndex: index,
            rect: rect,
            content: .signature(FillSignSignature(
                strokes: strokes,
                red: ink.red,
                green: ink.green,
                blue: ink.blue,
                penWidthFraction: FillSignSignature.defaultPenWidthFraction
            ))
        )
        items.append(item)
        selectedID = item.id
        signatureStrokes = []
    }

    private func placeTypedSignature() {
        let name = typedSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let index = clampedPageIndex()
        guard let box = pageBox(index) else { return }
        let fontSize: CGFloat = 30
        let width = min(max(box.width * 0.45, 160), box.width - 20)
        let height = fontSize * 1.7
        let rect = placementRect(size: CGSize(width: width, height: height), in: box, pageIndex: index)
        let ink = selectedInk
        let item = FillSignItem(
            pageIndex: index,
            rect: rect,
            content: .text(FillSignText(
                string: name,
                fontSize: fontSize,
                red: ink.red,
                green: ink.green,
                blue: ink.blue,
                isScript: true
            ))
        )
        items.append(item)
        selectedID = item.id
        typedSignature = ""
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }

    // MARK: Bindings into the selected item

    private func textBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let i = items.firstIndex(where: { $0.id == id }),
                      case .text(let t) = items[i].content else { return "" }
                return t.string
            },
            set: { newValue in
                guard let i = items.firstIndex(where: { $0.id == id }),
                      case .text(var t) = items[i].content else { return }
                t.string = newValue
                items[i].content = .text(t)
            }
        )
    }

    private func fontSizeBinding(id: UUID) -> Binding<CGFloat> {
        Binding(
            get: {
                guard let i = items.firstIndex(where: { $0.id == id }),
                      case .text(let t) = items[i].content else { return newFontSize }
                return t.fontSize
            },
            set: { newValue in
                guard let i = items.firstIndex(where: { $0.id == id }),
                      case .text(var t) = items[i].content else { return }
                t.fontSize = newValue
                items[i].content = .text(t)
            }
        )
    }

    // MARK: - Data

    private func reloadDocumentForSelection() async {
        // A different (or removed) file: the last run's confirmation no longer describes what's loaded.
        saveSummary = nil
        items = []
        selectedID = nil
        undo.reset([])
        // Clear the interaction flag in case the document changed mid-drag, so undo recording isn't
        // left gated off for the new document (the editor's .ended may not fire on teardown).
        canvasInteracting = false
        currentPageIndex = 0
        placementCascade = 0
        pdfDocument = nil
        guard let url = inputURL else { return }
        do {
            // Load off the main thread AND on the shared PDFKit serial queue: constructing
            // PDFDocument(url:) here directly beachballed the UI on slow volumes (the
            // "Opening PDF…" state could never render) and ran PDFKit concurrently with
            // queue-side work — the exact access pattern the serialization invariant forbids.
            let box = try await PDFBackgroundWork.run {
                try url.withSecurityScopedAccess { PDFDocumentBox(document: PDFDocument(url: url)) }
            }
            guard !Task.isCancelled else { return }
            if box.document == nil {
                alertMessage = PDFOperationError.couldNotOpen(url).localizedDescription
            } else if box.document?.isLocked == true {
                // A locked document loads "fine" but every page is a blank placeholder — the user
                // would place text and signatures on empty pages and only learn why at export.
                // Refuse at load with the same message the export guard uses, and CLEAR the
                // selection: leaving inputURL set stranded the pane on "Opening PDF…" forever
                // after the alert, and made re-selecting the same file (once unlocked) a no-op
                // because the task id never changed. Clean Metadata's refusal established this.
                alertMessage = PDFOperationError.encryptedInput(url).localizedDescription
                inputURL = nil
            } else {
                pdfDocument = box.document
            }
        } catch is CancellationError {
            // Superseded by another document switch; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pdfDocument = nil
            alertMessage = error.localizedDescription
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
    private func runFillSign() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }
        let inked = items.filter(\.hasInk)
        guard !inked.isEmpty else {
            alertMessage = PDFOperationError.noFillSignItems.localizedDescription
            return
        }

        busy = true
        saveSummary = nil
        AppStateManager.shared.beginOperation(Tool.fillSign.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.fillSign.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-filled.pdf"
        let itemsSnapshot = inked
        let additionCount = itemsSnapshot.count

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFToolkit.fillAndSignData(inputURL: fileURL, items: itemsSnapshot)
                }
            }
            let summary = ToolSaveSummary(
                title: "Saved with \(additionCount) addition\(additionCount == 1 ? "" : "s")",
                detail: "Your text and signatures are now part of the PDF.",
                url: nil
            )
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.fillSign.title,
                defaultStem: "filled",
                suffixWord: "filled"
            ) {
            case .savedBeside(let url):
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = summary
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.fillSign.title) failed: \(error.localizedDescription)")
        }
    }
}
