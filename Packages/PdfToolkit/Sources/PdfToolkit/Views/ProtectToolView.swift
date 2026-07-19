import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum ProtectMode: String, CaseIterable, Identifiable {
    case protect
    case remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .protect: return "Add password"
        case .remove: return "Remove password"
        }
    }
}

struct ProtectToolView: View {
    @State private var inputURL: URL?
    @State private var mode: ProtectMode = .protect
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPassword = ""

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "protected.pdf"
    @State private var isDropTargeted = false

    private var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    private var canRun: Bool {
        guard inputURL != nil else { return false }
        switch mode {
        case .protect: return passwordsMatch
        case .remove: return !currentPassword.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fileCard
                    modeCard
                    passwordCard
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(24)
            }

            Divider()

            RunActionButton(title: runTitle, busy: busy, canRun: canRun) {
                Task { await run() }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
            exportDoc = nil
            clearPasswords()
            if case .failure(let err) = result { alertMessage = err.localizedDescription }
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

    private var runTitle: String {
        mode == .protect ? "Protect & save…" : "Remove password & save…"
    }

    // MARK: - File

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.doc")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.protect.accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") { inputURL = nil }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Group {
                if inputURL == nil {
                    emptyDropZone
                } else if let url = inputURL {
                    selectedFileRow(url: url)
                }
            }
            .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                consumeDroppedProviders(providers)
                return true
            }
        }
        .padding(18)
        .formCard()
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.protect.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Add a password to lock a PDF, or remove one you can already open.")
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
                .foregroundStyle(isDropTargeted ? Tool.protect.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileRow(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.protect.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.protect.accent)
            }
            .accessibilityHidden(true)

            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout.weight(.medium))
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

    // MARK: - Mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("What to do", selection: $mode) {
                ForEach(ProtectMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(mode == .protect
                 ? "Encrypt the PDF so it can only be opened with the password you set."
                 : "Write an unlocked copy of a PDF you can open with its current password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .protect:
                labeledSecureField("New password", text: $newPassword, prompt: "Required to open the PDF")
                labeledSecureField("Confirm password", text: $confirmPassword, prompt: "Re-enter the password")
                if !confirmPassword.isEmpty && !passwordsMatch {
                    Label("Passwords don't match yet.", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Label("If you forget this password, the file cannot be opened — there is no recovery.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .remove:
                labeledSecureField("Current password", text: $currentPassword, prompt: "The password that opens this PDF")
                Label("The saved copy will open without any password.", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .formCard()
    }

    private func labeledSecureField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Drop

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

    private func clearPasswords() {
        newPassword = ""
        confirmPassword = ""
        currentPassword = ""
    }

    // MARK: - Run

    @MainActor
    private func run() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.protect.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.protect.title)
        }

        let base = fileURL.deletingPathExtension().lastPathComponent
        let modeSnapshot = mode
        let secret = modeSnapshot == .protect ? newPassword : currentPassword
        suggestedName = base + (modeSnapshot == .protect ? "-protected.pdf" : "-unlocked.pdf")

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        switch modeSnapshot {
                        case .protect:
                            try PDFToolkit.encrypt(inputURL: fileURL, outputURL: out, password: secret)
                        case .remove:
                            try PDFToolkit.removePassword(inputURL: fileURL, outputURL: out, password: secret)
                        }
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
