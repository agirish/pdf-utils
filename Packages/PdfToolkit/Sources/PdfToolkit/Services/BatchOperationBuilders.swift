import Foundation

/// Pure translations from each in-tool "Multiple files" configuration to the ``BatchOperation`` the
/// tool runs across its queue.
///
/// The tool views own the UI state and call these; keeping the single→batch mapping here (unit
/// conversions, empty-field guards, sub-mode selection) puts it in one place that unit tests can
/// exercise directly, instead of burying it in SwiftUI view bodies where it can't be reached.
extension BatchOperation {

    /// Compress: the quality slider maps straight through; target-size converts megabytes → bytes and
    /// is `nil` when the field is cleared (there is no size to aim for). Mirrors `CompressToolView`.
    static func compressConfig(usesTargetSize: Bool, quality: Double, targetMegabytes: Double) -> BatchOperation? {
        if usesTargetSize {
            guard targetMegabytes > 0 else { return nil }
            return .compressTarget(targetBytes: max(1, Int((targetMegabytes * 1_048_576).rounded())))
        }
        return .compressQuality(quality: quality)
    }

    /// Rotate: a pass-through of the chosen quarter-turns. Batch rotate turns every page of every file,
    /// so there is no page scope to translate. Mirrors `RotateToolView`.
    static func rotateConfig(quarterTurns: Int) -> BatchOperation {
        .rotate(quarterTurns: quarterTurns)
    }

    /// Watermark: `nil` when the text is blank (nothing to stamp); otherwise the trimmed text and the
    /// chosen style become `WatermarkOptions`. Mirrors `WatermarkToolView`.
    static func watermarkConfig(
        text: String,
        fontSize: CGFloat,
        opacity: CGFloat,
        rotationDegrees: CGFloat,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        tiled: Bool
    ) -> BatchOperation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .watermark(WatermarkOptions(
            text: trimmed,
            fontSize: fontSize,
            opacity: opacity,
            rotationDegrees: rotationDegrees,
            red: red,
            green: green,
            blue: blue,
            tiled: tiled
        ))
    }

    /// Protect · Add password: `nil` until the two entries match and are non-empty. Mirrors
    /// `ProtectToolView`'s `passwordsMatch`.
    static func encryptConfig(newPassword: String, confirmPassword: String) -> BatchOperation? {
        guard !newPassword.isEmpty, newPassword == confirmPassword else { return nil }
        return .encrypt(password: newPassword)
    }

    /// Protect · Remove password: `nil` until a current password is entered. Mirrors `ProtectToolView`.
    static func removePasswordConfig(currentPassword: String) -> BatchOperation? {
        guard !currentPassword.isEmpty else { return nil }
        return .removePassword(password: currentPassword)
    }
}
