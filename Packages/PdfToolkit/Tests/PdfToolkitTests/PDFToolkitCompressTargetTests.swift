import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Target-size compression sweeps a bounded ladder of qualities and keeps the best-fitting result.
/// The `selectBestAttempt` tests pin the pure decision (highest quality that fits, else smallest
/// file) with no file IO; the `compressToTarget` tests confirm the loop wires that decision into a
/// real, openable PDF — including the "target impossible" fallback and the unreadable-source guard.
@Suite struct PDFToolkitCompressTargetTests {

    private func attempt(_ quality: Double, _ bytes: Int) -> CompressionAttempt {
        CompressionAttempt(quality: quality, byteCount: bytes)
    }

    // MARK: - Pure selection

    @Test func picksHighestQualityThatFitsUnderTarget() {
        let attempts = [attempt(0.9, 5000), attempt(0.6, 2500), attempt(0.3, 1200)]
        #expect(PDFToolkit.selectBestAttempt(from: attempts, targetBytes: 3000) == attempt(0.6, 2500))
    }

    @Test func picksHighestQualityWhenEveryAttemptFits() {
        let attempts = [attempt(0.9, 800), attempt(0.6, 500), attempt(0.3, 300)]
        #expect(PDFToolkit.selectBestAttempt(from: attempts, targetBytes: 5000) == attempt(0.9, 800))
    }

    @Test func treatsAttemptEqualToTargetAsFitting() {
        let attempts = [attempt(0.9, 4000), attempt(0.6, 3000)]
        #expect(PDFToolkit.selectBestAttempt(from: attempts, targetBytes: 3000) == attempt(0.6, 3000))
    }

    @Test func fallsBackToSmallestFileWhenNothingFits() {
        let attempts = [attempt(0.9, 9000), attempt(0.6, 7000), attempt(0.3, 6000)]
        #expect(PDFToolkit.selectBestAttempt(from: attempts, targetBytes: 3000) == attempt(0.3, 6000))
    }

    @Test func returnsNilWhenNoAttemptsWereMade() {
        #expect(PDFToolkit.selectBestAttempt(from: [], targetBytes: 1000) == nil)
    }

    // MARK: - End-to-end

    @Test func generousTargetProducesAValidPDF() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: 5_000_000)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func unreachableTargetStillWritesTheSmallestResult() throws {
        // A 1-byte budget can't be met, but the tool must still emit the most-compressed attempt
        // rather than fail — a valid 2-page PDF comes out.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: 1)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compressToTarget(inputURL: bad, outputURL: dir.url("out.pdf"), targetBytes: 1000)
        }?.kind == "couldNotOpen")
    }

    @Test func refusesToOverwriteItsOwnSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compressToTarget(inputURL: src, outputURL: src, targetBytes: 1000)
        }?.kind == "outputMatchesInput")
    }
}
