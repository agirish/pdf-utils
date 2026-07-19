import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Extract, Reorder, and Delete all rebuild a document from copied pages. They share a page-copy
/// path, so the tests focus on each one's distinct contract: extract preserves the requested order
/// and duplicates, reorder is a full permutation, and delete removes from the highest index down
/// while refusing to empty the document.
@Suite struct PDFToolkitExtractReorderDeleteTests {

    // MARK: - Extract

    @Test func extractCopiesPagesInTheRequestedOrder() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P1"))
    }

    @Test func extractCanRepeatAPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [0, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.contains("P1") })
    }

    @Test func extractRejectsEmptySelection() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.extract(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [])
        }?.kind == "noPagesSelected")
    }

    @Test func extractRejectsOutOfBoundsPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.extract(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [5])
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    // MARK: - Reorder

    @Test func reorderAppliesAFullPermutation() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 1, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P2"))
        #expect(texts[2].contains("P1"))
    }

    @Test func reorderWithIdentityOrderCopiesUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [0, 1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("P1"))
        #expect(texts[1].contains("P2"))
    }

    // MARK: - Delete

    @Test func deleteRemovesTheNamedPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P1"))
        #expect(texts[1].contains("P3"))
    }

    @Test func deleteFromHighestIndexDownKeepsTheRightPages() throws {
        // Removing [0,1] must delete the first two pages, not shift and delete the wrong ones —
        // the engine sorts descending so earlier removals don't renumber later ones.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [0, 1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 1)
        #expect(texts[0].contains("P3"))
    }

    @Test func deleteDeduplicatesRepeatedIndices() throws {
        // Naming a page twice removes it once — the count reflects a single deletion.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1, 1])

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func deleteRefusesToRemoveEveryPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [0, 1, 2])
        }?.kind == "cannotRemoveEveryPage")
    }

    @Test func deleteRejectsEmptySelection() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [])
        }?.kind == "noPagesSelected")
    }

    @Test func deleteRejectsOutOfBoundsPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [5])
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }
}
