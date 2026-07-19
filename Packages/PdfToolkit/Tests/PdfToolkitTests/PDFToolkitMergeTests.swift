import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Merge concatenates whole PDFs in list order. The engine moves pages out of each freshly-loaded
/// source document, so the tests pin order, page totals, per-page content, and the open/empty
/// failure paths on real files.
@Suite struct PDFToolkitMergeTests {

    @Test func concatenatesInListOrderAndSumsPages() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ALPHA", "BETA"], to: a)
        try PDFFixtures.writePDF(markers: ["GAMMA"], to: b)

        try PDFToolkit.merge(inputURLs: [a, b], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains("ALPHA"))
        #expect(texts[1].contains("BETA"))
        #expect(texts[2].contains("GAMMA"))
    }

    @Test func orderFollowsTheInputArrayNotDisk() throws {
        // Reversing the input array reverses the merged page order — order is caller-controlled.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ALPHA"], to: a)
        try PDFFixtures.writePDF(markers: ["GAMMA"], to: b)

        try PDFToolkit.merge(inputURLs: [b, a], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("GAMMA"))
        #expect(texts[1].contains("ALPHA"))
    }

    @Test func singleFileIsCopiedWholesale() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: a)
        try PDFToolkit.merge(inputURLs: [a], outputURL: out)
        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func sameFileTwiceDuplicatesItsPages() throws {
        // Each list entry is loaded independently, so listing a file twice legitimately doubles it.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONE", "TWO"], to: a)

        try PDFToolkit.merge(inputURLs: [a, a], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 4)
        #expect(texts[0].contains("ONE"))
        #expect(texts[3].contains("TWO"))
    }

    @Test func emptyInputListThrowsNoInputFiles() {
        let dir = FixtureDir()
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputURLs: [], outputURL: dir.url("out.pdf"))
        }?.kind == "noInputFiles")
    }

    @Test func corruptInputThrowsCouldNotOpenNamingTheFile() throws {
        let dir = FixtureDir()
        let good = dir.url("good.pdf"), bad = dir.url("bad.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: good)
        try PDFFixtures.writeCorrupt(to: bad)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputURLs: [good, bad], outputURL: out)
        }
        if case .couldNotOpen(let url)? = error { #expect(url == bad) } else {
            Issue.record("expected couldNotOpen(bad), got \(String(describing: error))")
        }
        // A failed merge leaves no output file behind.
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
