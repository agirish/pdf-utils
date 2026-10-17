import Foundation
import PDFKit
import PDFToolkitCore
import SwiftUI

/// The amber advisory banner for an ``OutputFidelityWarning``.
///
/// Amber, not red: this is a real consequence the user should see, but the operation is still valid
/// and will run — the codebase reserves red for hard errors (see ``RangeFieldNote``).
struct OutputFidelityNote: View {
    let warning: OutputFidelityWarning
    let toolTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning.symbolName)
                .font(.caption)
                .foregroundStyle(Color.fieldWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.headline)
                    .font(.caption.weight(.medium))
                ForEach(Array(warning.detailLines(toolTitle: toolTitle).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !warning.keptLine.isEmpty {
                    Text(warning.keptLine)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color.fieldWarning)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.fieldWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: LiquidGlass.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.rowRadius)
                .strokeBorder(Color.fieldWarning.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. \(warning.headline). \(warning.detail(toolTitle: toolTitle))")
    }
}

/// Tracks a tool's pending fidelity warning and whether the user has acknowledged it.
///
/// The acknowledgement is per-warning, not per-session: swapping in a different file re-arms the
/// confirmation, so a user who accepted flattening for one form can't have it silently applied to
/// the next document they load.
@MainActor
final class OutputFidelityGate: ObservableObject {
    @Published private(set) var warning: OutputFidelityWarning?
    @Published var isConfirming = false
    /// True only while a *click* is waiting for detection to finish — the run button shows its
    /// spinner for exactly that moment. Deliberately not set during ordinary background detection:
    /// disabling the button on every file load would read as the app being slow, when the
    /// overwhelming majority of files have nothing to warn about.
    @Published private(set) var isSettling = false
    private var acknowledged: OutputFidelityWarning?
    /// The in-flight detection, so a click can await the answer instead of racing it.
    private var detectionTask: Task<Void, Never>?
    /// Guards against a superseded detection publishing its stale result.
    private var generation = 0

    /// Replaces the current warning. Clears the acknowledgement whenever the warning changes, so a
    /// newly loaded file must be confirmed on its own terms.
    func update(_ new: OutputFidelityWarning?) {
        guard new != warning else { return }
        warning = new
        acknowledged = nil
    }

    /// True when the caller may proceed straight to saving. When false, the confirmation is raised
    /// and the caller should return — the confirm action re-enters the save.
    func shouldProceed() -> Bool {
        guard let warning, acknowledged != warning else { return true }
        isConfirming = true
        return false
    }

    /// Records the user's acknowledgement so the re-entered save runs through.
    func acknowledge() {
        acknowledged = warning
        isConfirming = false
    }

    /// Re-detects the warning for `urls`. The detector opens PDFs, so it runs on the shared serial
    /// queue — never on the main actor, and never alongside other PDFKit work.
    func refresh(urls: [URL], detect: @escaping @Sendable ([URL]) -> OutputFidelityWarning?) async {
        generation += 1
        let generationAtStart = generation
        guard !urls.isEmpty else {
            detectionTask?.cancel()
            detectionTask = nil
            update(nil)
            return
        }
        // Owned by an inner task rather than run inline, so ``settle()`` has something to await —
        // the SwiftUI `.task` this runs inside is cancelled on a file switch, which would otherwise
        // leave a click with no way to know detection was ever in flight.
        let task = Task { @MainActor [weak self] in
            let detected = try? await PDFBackgroundWork.run { detect(urls) }
            guard let self, self.generation == generationAtStart else { return }
            self.update(detected ?? nil)
        }
        detectionTask = task
        await task.value
    }

    /// Whether a detection pass has been started for the current file set. Exposed so a test can
    /// wait for `.task`'s refresh to actually begin before simulating the click — without it the
    /// test races the runtime rather than the code.
    ///
    /// Note the boundary this implies: ``settle()`` waits for a detection that has STARTED. A click
    /// landing before the view's `.task` body has even run would still slip past — unreachable from
    /// the UI, where `.task` fires on appearance and a human click cannot precede it, but worth
    /// knowing if this is ever driven from somewhere else.
    var detectionHasStarted: Bool { detectionTask != nil }

    /// Waits for any in-flight detection so a Save click can't beat it to the answer.
    ///
    /// Returns immediately when detection has already finished — the common case, since a user
    /// reading the sidebar takes far longer than a catalog read. Only when the click genuinely
    /// arrives first does `isSettling` flip, showing the button's spinner for that moment.
    func settle() async {
        guard let task = detectionTask else { return }
        isSettling = true
        await task.value
        isSettling = false
    }

    /// The shape every tool uses: it declares how it damages a form and whether it drops bookmarks.
    func refresh(urls: [URL], formLoss: OutputFidelityWarning.Loss?, checksBookmarks: Bool) async {
        await refresh(urls: urls) { urls in
            OutputFidelityWarning.detect(in: urls, formLoss: formLoss, checksBookmarks: checksBookmarks)
        }
    }
}

extension View {
    /// The confirmation a fidelity warning must pass before a tool writes its output. `onConfirm`
    /// re-enters the same save action — the gate lets it through once acknowledged.
    func outputFidelityConfirmation(
        _ gate: OutputFidelityGate,
        toolTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(
            gate.warning?.confirmationTitle ?? "",
            isPresented: Binding(get: { gate.isConfirming }, set: { gate.isConfirming = $0 }),
            presenting: gate.warning
        ) { warning in
            Button(warning.confirmButtonTitle) {
                gate.acknowledge()
                onConfirm()
            }
            Button("Cancel", role: .cancel) { gate.isConfirming = false }
        } message: { warning in
            Text(warning.detail(toolTitle: toolTitle))
        }
    }
}
