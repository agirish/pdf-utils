import Testing
import Foundation
@testable import PdfToolkit

/// Each in-tool "Multiple files" mode builds a `BatchOperation` from its own config. These lock the
/// single→batch mapping the four tool views call (unit conversions, empty-field guards, sub-mode
/// selection) so a UI refactor can't silently change what a batch run does.
@Suite struct BatchOperationBuilderTests {

    // MARK: Compress

    @Test func compressQualityModePassesTheQualityThrough() {
        let op = BatchOperation.compressConfig(usesTargetSize: false, quality: 0.6, targetMegabytes: 2)
        guard case .compressQuality(let q) = op else {
            Issue.record("expected .compressQuality, got \(String(describing: op))"); return
        }
        #expect(q == 0.6)
    }

    @Test func compressTargetModeConvertsMegabytesToBytes() {
        let op = BatchOperation.compressConfig(usesTargetSize: true, quality: 0.6, targetMegabytes: 2)
        guard case .compressTarget(let bytes) = op else {
            Issue.record("expected .compressTarget, got \(String(describing: op))"); return
        }
        #expect(bytes == 2 * 1_048_576) // 2 MiB, matching the field's MB unit
    }

    @Test func compressTargetModeIsNilWhenTheTargetIsCleared() {
        #expect(BatchOperation.compressConfig(usesTargetSize: true, quality: 0.6, targetMegabytes: 0) == nil)
    }

    // MARK: Rotate

    @Test func rotatePassesTheQuarterTurnsThrough() {
        guard case .rotate(let turns) = BatchOperation.rotateConfig(quarterTurns: 3) else {
            Issue.record("expected .rotate"); return
        }
        #expect(turns == 3)
    }

    // MARK: Watermark

    @Test func watermarkTrimsTextAndThreadsTheChosenStyle() {
        let op = BatchOperation.watermarkConfig(
            text: "  DRAFT ", fontSize: 48, opacity: 0.25, rotationDegrees: 45,
            red: 0.8, green: 0.12, blue: 0.12, tiled: true
        )
        guard case .watermark(let options) = op else {
            Issue.record("expected .watermark, got \(String(describing: op))"); return
        }
        #expect(options.text == "DRAFT")          // trimmed
        #expect(options.fontSize == 48)
        #expect(options.opacity == 0.25)
        #expect(options.rotationDegrees == 45)
        #expect(options.red == 0.8)
        #expect(options.green == 0.12)
        #expect(options.blue == 0.12)
        #expect(options.tiled == true)
    }

    @Test func watermarkIsNilForBlankOrWhitespaceText() {
        #expect(BatchOperation.watermarkConfig(
            text: "   \n", fontSize: 48, opacity: 0.25, rotationDegrees: 45,
            red: 0, green: 0, blue: 0, tiled: false) == nil)
    }

    // MARK: Protect

    @Test func encryptRequiresMatchingNonEmptyPasswords() {
        guard case .encrypt(let pw) = BatchOperation.encryptConfig(newPassword: "s3cret", confirmPassword: "s3cret") else {
            Issue.record("expected .encrypt"); return
        }
        #expect(pw == "s3cret")
    }

    @Test func encryptIsNilWhenPasswordsMismatchOrAreEmpty() {
        #expect(BatchOperation.encryptConfig(newPassword: "a", confirmPassword: "b") == nil)
        #expect(BatchOperation.encryptConfig(newPassword: "", confirmPassword: "") == nil)
    }

    @Test func removePasswordRequiresANonEmptyCurrentPassword() {
        guard case .removePassword(let pw) = BatchOperation.removePasswordConfig(currentPassword: "open") else {
            Issue.record("expected .removePassword"); return
        }
        #expect(pw == "open")
        #expect(BatchOperation.removePasswordConfig(currentPassword: "") == nil)
    }
}
