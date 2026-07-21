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
    @State private var mode: ProtectMode = .protect
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPassword = ""

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "protected.pdf"

    @StateObject private var runner = BatchRunner()

    private var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    /// The current sub-mode + password as a batch operation, mirroring `run()`. Nil until the
    /// passwords are valid (matching for Add, non-empty for Remove) — which also gates the action.
    private var currentBatchOperation: BatchOperation? {
        switch mode {
        case .protect:
            return .encryptConfig(newPassword: newPassword, confirmPassword: confirmPassword)
        case .remove:
            return .removePasswordConfig(currentPassword: currentPassword)
        }
    }

    private var runTitle: String {
        mode == .protect ? "Protect & save…" : "Remove password & save…"
    }

    var body: some View {
        UnifiedFilePanel(
            runner: runner,
            tool: .protect,
            singleActionTitle: runTitle,
            busy: $busy,
            makeOperation: { currentBatchOperation },
            fallbackSuffix: mode == .protect ? "protected" : "unlocked",
            previewSubtitle: "The pages of the PDF you’re about to protect or unlock.",
            // Protect is the one tool whose sidebar can actually fix a locked file, so its
            // placeholder points at the field on the left instead of at another tool.
            lockedPreviewMessage: "This PDF is password-protected. Enter its password on the left, then remove it to preview and unlock the file.",
            runSingle: { url in await run(url) }
        ) {
            modeCard
            passwordCard
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: suggestedName.exportFilenameStem
        ) { result in
            let savedBytes = exportDoc?.data.count
            exportDoc = nil
            clearPasswords()
            switch result {
            case .success(let url):
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.protect.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.protect.title) failed: \(err.localizedDescription)")
            }
        }
        .toolErrorAlert($alertMessage)
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
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Label("If you forget this password, the file cannot be opened — there is no recovery.",
                      systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .remove:
                labeledSecureField("Current password", text: $currentPassword, prompt: "The password that opens this PDF")
                Label("The saved copy will open without any password.", systemImage: "lock.open")
                    .font(.subheadline)
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

    private func clearPasswords() {
        newPassword = ""
        confirmPassword = ""
        currentPassword = ""
    }

    // MARK: - Single-file run

    @MainActor
    private func run(_ fileURL: URL) async {
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
                    switch modeSnapshot {
                    case .protect:
                        return try PDFToolkit.encryptData(inputURL: fileURL, password: secret)
                    case .remove:
                        return try PDFToolkit.removePasswordData(inputURL: fileURL, password: secret)
                    }
                }
            }
            let suffixWord = modeSnapshot == .protect ? "protected" : "unlocked"
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.protect.title,
                defaultStem: suffixWord,
                suffixWord: suffixWord
            ) {
            case .savedBeside:
                // Same hygiene as the export-sheet path: a finished save must not leave the
                // password sitting in the fields (and in @State).
                clearPasswords()
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.protect.title) failed: \(error.localizedDescription)")
        }
    }
}
