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

/// The two ways Add-password encrypts. `lockToOpen` is the original single-password behavior; the file
/// can't be opened without it. `restrictEditing` sets the same string as an *owner* password only, so
/// the file opens and prints freely but copying text and editing need the password — the "printable
/// but locked" permission mode PDFs support.
private enum ProtectionStyle: String, CaseIterable, Identifiable {
    case lockToOpen
    case restrictEditing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockToOpen: return "Lock to open"
        case .restrictEditing: return "Restrict editing"
        }
    }
}

struct ProtectToolView: View {
    @State private var mode: ProtectMode = .protect
    @State private var protectionStyle: ProtectionStyle = .lockToOpen
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPassword = ""
    /// Reveals the typed passwords in plain text — the standard show/hide affordance, so a long
    /// password can be checked before it locks a file with no recovery.
    @State private var showPasswords = false

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "protected.pdf"

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?

    @StateObject private var runner = BatchRunner()

    @Environment(\.toolAccent) private var accent

    private var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    private var restrictEditing: Bool { protectionStyle == .restrictEditing }

    /// The current sub-mode + password as a batch operation, mirroring `run()`. Nil until the
    /// passwords are valid (matching for Add, non-empty for Remove) — which also gates the action.
    private var currentBatchOperation: BatchOperation? {
        switch mode {
        case .protect:
            return .encryptConfig(restrictEditing: restrictEditing, newPassword: newPassword, confirmPassword: confirmPassword)
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
            runSingle: { url in await run(url) },
            // Adding a password serializes the document in place and keeps an interactive form;
            // removing one rebuilds by copying pages, which orphans it (verified empirically).
            detectFidelityWarning: { [mode] urls in
                guard mode == .remove else { return nil }
                return OutputFidelityWarning.detect(in: urls, formLoss: .formOrphaned, checksBookmarks: false)
            },
            fidelityRefreshToken: mode == .protect ? "protect" : "remove"
        ) {
            // The banner is a single-file receipt; don't let it linger once the queue is a batch.
            if let saveSummary, runner.items.count <= 1 {
                ToolSaveBanner(accent: accent, summary: saveSummary)
            }
            modeCard
            if mode == .protect {
                styleCard
            }
            passwordCard
        }
        .onChange(of: runner.items.first?.url) { _, _ in
            // A different (or removed) file: the last run's confirmation no longer describes what's loaded.
            saveSummary = nil
        }
        .onChange(of: runner.items.count) { _, _ in
            // Adding a second file (which leaves the first URL unchanged) turns this into a batch;
            // the single-file receipt no longer applies.
            saveSummary = nil
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
                // Clear the password only on a real save — a cancelled dialog should leave the fields
                // populated so the user can retry, matching the error path (which also retains them).
                clearPasswords()
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.protect.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.protect.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
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
                 ? "Add a password to a PDF — either to open it, or to lock editing while it still opens."
                 : "Write an unlocked copy of a PDF you can open with its current password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Protection style (Add-password only)

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Protection", selection: $protectionStyle) {
                ForEach(ProtectionStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(restrictEditing
                 ? "Anyone can open and print the file. The password is required to copy text, edit, or lift the restriction."
                 : "The file can only be opened with the password. Once open, the reader has full access.")
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
                passwordField(newPasswordLabel, text: $newPassword, prompt: newPasswordPrompt)
                if !newPassword.isEmpty {
                    PasswordStrengthMeter(strength: PasswordStrengthEstimator.estimate(newPassword), accent: accent)
                }
                passwordField("Confirm password", text: $confirmPassword, prompt: "Re-enter the password")
                if !confirmPassword.isEmpty && !passwordsMatch {
                    Label("Passwords don't match yet.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.fieldWarning)
                }
                showPasswordToggle
                Label(restrictEditing
                      ? "If you forget this password, the restriction can’t be changed later — there is no recovery."
                      : "If you forget this password, the file cannot be opened — there is no recovery.",
                      systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .remove:
                passwordField("Current password", text: $currentPassword, prompt: "The password that opens this PDF")
                showPasswordToggle
                Label("The saved copy will open without any password.", systemImage: "lock.open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .formCard()
    }

    private var newPasswordLabel: String {
        restrictEditing ? "Owner password" : "New password"
    }

    private var newPasswordPrompt: String {
        restrictEditing ? "Required to edit or copy" : "Required to open the PDF"
    }

    /// A labelled password field that honors the show/hide toggle: `SecureField` when hidden (the
    /// default), a plain `TextField` when revealed.
    private func passwordField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Group {
                if showPasswords {
                    TextField(prompt, text: text)
                } else {
                    SecureField(prompt, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .autocorrectionDisabled()
        }
    }

    private var showPasswordToggle: some View {
        Toggle("Show password", isOn: $showPasswords)
            .toggleStyle(.checkbox)
            .font(.subheadline)
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
        saveSummary = nil
        AppStateManager.shared.beginOperation(Tool.protect.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.protect.title)
        }

        let base = fileURL.deletingPathExtension().lastPathComponent
        let modeSnapshot = mode
        let styleSnapshot = protectionStyle
        suggestedName = base + (modeSnapshot == .protect ? "-protected.pdf" : "-unlocked.pdf")
        let summary = summaryText(mode: modeSnapshot, style: styleSnapshot)

        do {
            let protection = ProtectionOptions.addPassword(
                restrictEditing: styleSnapshot == .restrictEditing,
                password: newPassword
            )
            let removalSecret = currentPassword
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    switch modeSnapshot {
                    case .protect:
                        return try PDFToolkit.encryptData(inputURL: fileURL, options: protection)
                    case .remove:
                        return try PDFToolkit.removePasswordData(inputURL: fileURL, password: removalSecret)
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
            case .savedBeside(let url):
                // Same hygiene as the export-sheet path: a finished save must not leave the
                // password sitting in the fields (and in @State).
                clearPasswords()
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: nil)
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.protect.title) failed: \(error.localizedDescription)")
        }
    }

    /// The confirmation copy for a finished run, snapshotted before the save so it reflects the mode
    /// and style that actually ran (not whatever the fields hold by the time a dialog returns).
    private func summaryText(mode: ProtectMode, style: ProtectionStyle) -> (title: String, detail: String) {
        switch mode {
        case .protect:
            return style == .restrictEditing
                ? ("Editing restricted", "The saved copy opens and prints freely; copying and editing need the password.")
                : ("Password added", "The saved copy opens only with the password you set.")
        case .remove:
            return ("Password removed", "The saved copy opens without any password.")
        }
    }
}

/// A four-segment strength readout for the Protect password field. A UX nudge only — see
/// ``PasswordStrengthEstimator`` — so it stays visual and quiet rather than blocking a save.
private struct PasswordStrengthMeter: View {
    let strength: PasswordStrength
    let accent: Color

    private var tint: Color {
        switch strength {
        case .empty, .weak: return .orange
        case .fair: return .yellow
        case .good, .strong: return .green
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < strength.filledSegments ? tint : Color.primary.opacity(0.12))
                        .frame(height: 5)
                }
            }
            Text(strength.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(strength.label)")
    }
}
