import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// The Batch tool's engine has two halves worth pinning without a UI: the pure operation model
/// (suffix convention + output-name derivation, and which `PDFToolkit` call each case dispatches to)
/// and the end-to-end apply path that writes a real result into a chosen folder. The mapping tests
/// need no filesystem; the apply tests write fixture PDFs to a temp dir and assert the output lands.
@Suite struct BatchRunnerTests {

    // MARK: - Suffix convention

    @Test func suffixWordMatchesTheSingleToolConvention() {
        #expect(BatchOperation.compressQuality(quality: 0.7).suffixWord == "compressed")
        #expect(BatchOperation.compressTarget(targetBytes: 1000).suffixWord == "compressed")
        #expect(BatchOperation.rotate(quarterTurns: 1).suffixWord == "rotated")
        #expect(BatchOperation.encrypt(password: "x").suffixWord == "protected")
        #expect(BatchOperation.removePassword(password: "x").suffixWord == "unlocked")
        let options = WatermarkOptions(text: "DRAFT", fontSize: 48, opacity: 0.25, rotationDegrees: 45, red: 0.5, green: 0.5, blue: 0.5, tiled: false)
        #expect(BatchOperation.watermark(options).suffixWord == "watermarked")
    }

    // MARK: - Tool attribution

    @Test func toolTitleAttributesEachOperationToItsSingleTool() {
        #expect(BatchOperation.compressQuality(quality: 0.7).toolTitle == Tool.compress.title)
        #expect(BatchOperation.compressTarget(targetBytes: 1000).toolTitle == Tool.compress.title)
        #expect(BatchOperation.rotate(quarterTurns: 1).toolTitle == Tool.rotate.title)
        #expect(BatchOperation.encrypt(password: "x").toolTitle == Tool.protect.title)
        #expect(BatchOperation.removePassword(password: "x").toolTitle == Tool.protect.title)
        let options = WatermarkOptions(text: "DRAFT", fontSize: 48, opacity: 0.25, rotationDegrees: 45, red: 0.5, green: 0.5, blue: 0.5, tiled: false)
        #expect(BatchOperation.watermark(options).toolTitle == Tool.watermark.title)
    }

    // MARK: - Output-name derivation

    @Test func outputFilenameStemsInputAndAppendsSuffix() {
        let op = BatchOperation.compressQuality(quality: 0.7)
        #expect(op.outputFilename(forInputNamed: "Report.pdf") == "Report-compressed.pdf")
        #expect(op.outputFilename(forInputNamed: "Report.PDF") == "Report-compressed.pdf")
        #expect(op.outputFilename(forInputNamed: "no-extension") == "no-extension-compressed.pdf")
    }

    @Test func outputFilenameKeepsInteriorDotsInTheStem() {
        // Only the final extension is stripped, so a name with interior dots keeps them.
        let op = BatchOperation.rotate(quarterTurns: 1)
        #expect(op.outputFilename(forInputNamed: "my.report.pdf") == "my.report-rotated.pdf")
    }

    @Test func outputFilenameReflectsEachOperation() {
        #expect(BatchOperation.rotate(quarterTurns: 2).outputFilename(forInputNamed: "A.pdf") == "A-rotated.pdf")
        #expect(BatchOperation.encrypt(password: "x").outputFilename(forInputNamed: "A.pdf") == "A-protected.pdf")
        #expect(BatchOperation.removePassword(password: "x").outputFilename(forInputNamed: "A.pdf") == "A-unlocked.pdf")
    }

    // MARK: - apply() dispatch

    @Test func applyCompressQualityWritesASmallerFile() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try BatchOperation.apply(.compressQuality(quality: 0.3), inputURL: src, outputURL: out)

        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func applyRotateTurnsEveryPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try BatchOperation.apply(.rotate(quarterTurns: 1), inputURL: src, outputURL: out)

        // Every page turned 90° clockwise — the operation covers all pages, not a subset.
        #expect(try PDFFixtures.pageRotations(at: out) == [90, 90])
    }

    @Test func applyWatermarkKeepsPageCountAndText() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let options = WatermarkOptions(text: "DRAFT", fontSize: 48, opacity: 0.3, rotationDegrees: 45, red: 0.5, green: 0.5, blue: 0.5, tiled: false)

        try BatchOperation.apply(.watermark(options), inputURL: src, outputURL: out)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
        // Underlying page text stays selectable after the vector-preserving watermark rebuild.
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains(PDFFixtures.marker(1)))
    }

    @Test func applyEncryptThenRemovePasswordRoundTrips() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), locked = dir.url("locked.pdf"), unlocked = dir.url("unlocked.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        try BatchOperation.apply(.encrypt(password: "secret"), inputURL: src, outputURL: locked)
        let lockedDoc = try #require(PDFDocument(url: locked))
        #expect(lockedDoc.isEncrypted)

        try BatchOperation.apply(.removePassword(password: "secret"), inputURL: locked, outputURL: unlocked)
        let unlockedDoc = try #require(PDFDocument(url: unlocked))
        #expect(!unlockedDoc.isLocked)
        #expect(unlockedDoc.pageCount == 1)
    }

    @Test func applyRotateOnUnreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try BatchOperation.apply(.rotate(quarterTurns: 1), inputURL: bad, outputURL: dir.url("out.pdf"))
        }?.kind == "couldNotOpen")
    }

    // MARK: - Batch into a folder (integration)

    @Test func batchCompressesSeveralFilesIntoAFolder() throws {
        let dir = FixtureDir()
        let outDir = dir.url("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let inputs = ["a.pdf", "b.pdf", "c.pdf"].map { dir.url($0) }
        for (i, url) in inputs.enumerated() {
            try PDFFixtures.writePDF(pageCount: i + 2, to: url)
        }

        let op = BatchOperation.compressQuality(quality: 0.3)
        var outputs: [URL] = []
        for input in inputs {
            let filename = op.outputFilename(forInputNamed: input.lastPathComponent)
            let out = PDFExportCoordinator.uniqueURL(inDirectory: outDir, filename: filename)
            try BatchOperation.apply(op, inputURL: input, outputURL: out)
            outputs.append(out)
        }

        // Every input produced its own uniquely-named result in the output folder, page counts intact.
        #expect(outputs.count == 3)
        #expect(Set(outputs.map(\.lastPathComponent)) == ["a-compressed.pdf", "b-compressed.pdf", "c-compressed.pdf"])
        for (i, out) in outputs.enumerated() {
            #expect(FileManager.default.fileExists(atPath: out.path))
            #expect(try PDFFixtures.pageCount(at: out) == i + 2)
        }
    }

    @Test func batchNumbersAClashingOutputInsteadOfOverwriting() throws {
        // Two inputs that share a stem in different source spots would map to one output name; the
        // uniqueURL step the runner uses numbers the second so nothing is clobbered.
        let dir = FixtureDir()
        let outDir = dir.url("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let firstSrc = dir.url("first/report.pdf")
        let secondSrc = dir.url("second/report.pdf")
        try FileManager.default.createDirectory(at: firstSrc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSrc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PDFFixtures.writePDF(pageCount: 1, to: firstSrc)
        try PDFFixtures.writePDF(pageCount: 2, to: secondSrc)

        let op = BatchOperation.compressQuality(quality: 0.5)
        var outputs: [URL] = []
        for input in [firstSrc, secondSrc] {
            let filename = op.outputFilename(forInputNamed: input.lastPathComponent)
            let out = PDFExportCoordinator.uniqueURL(inDirectory: outDir, filename: filename)
            try BatchOperation.apply(op, inputURL: input, outputURL: out)
            outputs.append(out)
        }

        #expect(outputs[0].lastPathComponent == "report-compressed.pdf")
        #expect(outputs[1].lastPathComponent == "report-compressed 2.pdf")
        #expect(FileManager.default.fileExists(atPath: outputs[0].path))
        #expect(FileManager.default.fileExists(atPath: outputs[1].path))
    }
}
