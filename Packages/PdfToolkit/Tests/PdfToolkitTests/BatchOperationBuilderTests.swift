import Testing
import CoreGraphics
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
        #expect(bytes == 2 * 1_000_000) // 2 decimal MB, matching the field's "MB" label and size hint
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

    private func textOptions(_ text: String, tiled: Bool = true) -> WatermarkOptions {
        WatermarkOptions(
            text: text, fontSize: 48, opacity: 0.25, rotationDegrees: 45,
            red: 0.8, green: 0.12, blue: 0.12, tiled: tiled
        )
    }

    @Test func watermarkTrimsTextAndThreadsTheChosenStyle() {
        let op = BatchOperation.watermarkConfig(textOptions("  DRAFT "))
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
        #expect(BatchOperation.watermarkConfig(textOptions("   \n")) == nil)
    }

    @Test func watermarkThreadsFontAndPageScope() {
        var options = textOptions("DRAFT")
        options.fontName = "Helvetica Neue"
        options.pageScope = .firstPageOnly
        guard case .watermark(let out) = BatchOperation.watermarkConfig(options) else {
            Issue.record("expected .watermark"); return
        }
        #expect(out.fontName == "Helvetica Neue")
        #expect(out.pageScope == .firstPageOnly)
    }

    @Test func watermarkImageModeIsNilWithoutAnImageAndValidWithOne() {
        var noImage = textOptions("ignored")
        noImage.content = .image
        noImage.image = nil
        #expect(BatchOperation.watermarkConfig(noImage) == nil)

        var withImage = noImage
        withImage.image = WatermarkImage(cgImage: Self.solidImage())
        guard case .watermark(let out) = BatchOperation.watermarkConfig(withImage) else {
            Issue.record("expected .watermark for image mode with an image"); return
        }
        #expect(out.content == .image)
        #expect(out.image != nil)
    }

    /// A tiny opaque CGImage for the image-mode builder test (no file IO needed).
    private static func solidImage() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    // MARK: Protect

    @Test func encryptLockToOpenSetsUserAndOwnerToThePassword() {
        guard case .encrypt(let options) = BatchOperation.encryptConfig(restrictEditing: false, newPassword: "s3cret", confirmPassword: "s3cret") else {
            Issue.record("expected .encrypt"); return
        }
        #expect(options.userPassword == "s3cret")
        #expect(options.ownerPassword == "s3cret")
        #expect(options.permissionBits == nil)
    }

    @Test func encryptRestrictEditingSetsOwnerOnlyWithPrintPermissions() {
        guard case .encrypt(let options) = BatchOperation.encryptConfig(restrictEditing: true, newPassword: "s3cret", confirmPassword: "s3cret") else {
            Issue.record("expected .encrypt"); return
        }
        #expect(options.userPassword == "")                                  // opens freely
        #expect(options.ownerPassword == "s3cret")
        #expect(options.permissionBits == PDFPermissionPreset.openAndPrintOnly)
    }

    @Test func encryptIsNilWhenPasswordsMismatchOrAreEmpty() {
        #expect(BatchOperation.encryptConfig(restrictEditing: false, newPassword: "a", confirmPassword: "b") == nil)
        #expect(BatchOperation.encryptConfig(restrictEditing: false, newPassword: "", confirmPassword: "") == nil)
        #expect(BatchOperation.encryptConfig(restrictEditing: true, newPassword: "a", confirmPassword: "b") == nil)
    }

    @Test func removePasswordRequiresANonEmptyCurrentPassword() {
        guard case .removePassword(let pw) = BatchOperation.removePasswordConfig(currentPassword: "open") else {
            Issue.record("expected .removePassword"); return
        }
        #expect(pw == "open")
        #expect(BatchOperation.removePasswordConfig(currentPassword: "") == nil)
    }
}
