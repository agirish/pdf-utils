import Foundation

/// Pure translations from each in-tool "Multiple files" configuration to the ``BatchOperation`` the
/// tool runs across its queue.
///
/// The tool views own the UI state and call these; keeping the single→batch mapping here (unit
/// conversions, empty-field guards, sub-mode selection) puts it in one place that unit tests can
/// exercise directly, instead of burying it in SwiftUI view bodies where it can't be reached.
extension BatchOperation {

    /// The Compress "target size" field's accepted range in megabytes, mirroring its `Stepper(in:)`.
    /// The Stepper only bounds its own increments — a typed value can be anything — so the byte
    /// conversion clamps to this before it ever reaches `Int`.
    static let compressTargetRangeMB: ClosedRange<Double> = 0.1...500

    /// Megabytes → the byte budget the compress sweep receives, made crash-proof. `Int(Double)` TRAPS
    /// once the value exceeds `Int.max`, so a free-entry field (a ~13-digit MB figure) could hard-crash
    /// the app on the next render. Clamp into ``compressTargetRangeMB`` — treating a non-finite value
    /// (NaN / ±inf, which `min`/`max` can't order) as the low end — BEFORE the multiply-and-convert, so
    /// the result is always finite and in range. The non-crashing guarantee lives here, in the one
    /// conversion shared by `CompressToolView.targetBytes` and ``compressConfig(usesTargetSize:quality:targetMegabytes:)``,
    /// not merely behind the UI, so the single-file and batch paths are both safe.
    static func targetBytes(forMegabytes megabytes: Double) -> Int {
        let lo = compressTargetRangeMB.lowerBound
        let hi = compressTargetRangeMB.upperBound
        let clamped = megabytes.isFinite ? min(max(megabytes, lo), hi) : lo
        return Int((clamped * 1_000_000).rounded())
    }

    /// Compress: the quality slider maps straight through; target-size converts megabytes → bytes and
    /// is `nil` when the field is cleared (there is no size to aim for). Mirrors `CompressToolView`,
    /// including its decimal-MB (1,000,000) unit so the "MB" field matches the shown source size.
    static func compressConfig(usesTargetSize: Bool, quality: Double, targetMegabytes: Double) -> BatchOperation? {
        if usesTargetSize {
            guard targetMegabytes > 0 else { return nil }
            return .compressTarget(targetBytes: targetBytes(forMegabytes: targetMegabytes))
        }
        return .compressQuality(quality: quality)
    }

    /// Rotate: a pass-through of the chosen quarter-turns. Batch rotate turns every page of every file,
    /// so there is no page scope to translate. Mirrors `RotateToolView`.
    static func rotateConfig(quarterTurns: Int) -> BatchOperation {
        .rotate(quarterTurns: quarterTurns)
    }

    /// Watermark: `nil` when there is nothing to stamp — blank text in text mode, or no chosen image
    /// in image mode — so the run button disables just like the other tools' empty-field guards.
    /// The text is trimmed so a batch stamps exactly what the single run does. Mirrors
    /// `WatermarkToolView`, which builds the same `WatermarkOptions` for its single-file path.
    static func watermarkConfig(_ options: WatermarkOptions) -> BatchOperation? {
        switch options.content {
        case .text:
            guard !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        case .image:
            guard options.image != nil else { return nil }
        }
        var normalized = options
        normalized.text = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .watermark(normalized)
    }

    /// Protect · Add password: `nil` until the two entries match and are non-empty. Mirrors
    /// `ProtectToolView`'s `passwordsMatch`. `restrictEditing` picks the style: when off, the password
    /// is set as both the user and owner password (locked to open); when on, it becomes the owner
    /// password only and the file opens/prints freely while copying and editing stay locked.
    static func encryptConfig(restrictEditing: Bool, newPassword: String, confirmPassword: String) -> BatchOperation? {
        guard !newPassword.isEmpty, newPassword == confirmPassword else { return nil }
        return .encrypt(ProtectionOptions.addPassword(restrictEditing: restrictEditing, password: newPassword))
    }

    /// Protect · Remove password: `nil` until a current password is entered. Mirrors `ProtectToolView`.
    ///
    /// `passwordUnused` is the one exception: when every queued file carries owner restrictions only
    /// (``PDFEncryptionState/restrictedOnly``), no password can be verified or is needed, the tool
    /// hides the field, and an empty entry must still be runnable.
    static func removePasswordConfig(currentPassword: String, passwordUnused: Bool = false) -> BatchOperation? {
        guard passwordUnused || !currentPassword.isEmpty else { return nil }
        return .removePassword(password: currentPassword)
    }
}
