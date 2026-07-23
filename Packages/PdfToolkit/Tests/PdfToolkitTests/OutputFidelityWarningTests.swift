import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// The warnings shown before a tool writes output that will genuinely lose something: form fields
/// flattened by a page rebuild, and bookmarks dropped by Merge/Split. Both are conditional — they
/// must appear only when the loaded file actually HAS the thing at risk, or they become wallpaper.
struct OutputFidelityWarningTests {

    private func pdfWithBookmarks(_ count: Int, in dir: FixtureDir, named name: String) throws -> URL {
        let plain = dir.url("plain-\(name)")
        try PDFFixtures.writePDF(pageCount: max(1, count), to: plain)
        let doc = try #require(PDFDocument(url: plain))
        if count > 0 {
            let root = PDFOutline()
            for i in 0..<count {
                let child = PDFOutline()
                child.label = "Bookmark \(i + 1)"
                child.destination = PDFDestination(page: try #require(doc.page(at: i)), at: .zero)
                root.insertChild(child, at: root.numberOfChildren)
            }
            doc.outlineRoot = root
        }
        let url = dir.url(name)
        try #require(doc.write(to: url))
        return url
    }

    // MARK: Bookmarks

    @Test func bookmarkCountWalksTheWholeTree() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try #require(PDFDocument(url: plain))
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Part I"
        parent.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: .zero)
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: try #require(doc.page(at: 1)), at: .zero)
        parent.insertChild(child, at: 0)
        root.insertChild(parent, at: 0)
        doc.outlineRoot = root
        let url = dir.url("nested.pdf")
        try #require(doc.write(to: url))

        #expect(PDFToolkit.bookmarkCount(at: url) == 2, "nested children must be counted")
    }

    @Test func noBookmarksMeansNoWarning() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: plain)
        #expect(PDFToolkit.bookmarkCount(at: plain) == 0)
        #expect(OutputFidelityWarning.bookmarks(in: [plain]) == nil)
    }

    @Test func bookmarkWarningTotalsAcrossOnlyTheFilesThatHaveThem() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(3, in: dir, named: "a.pdf")
        let b = try pdfWithBookmarks(0, in: dir, named: "b.pdf")
        let c = try pdfWithBookmarks(2, in: dir, named: "c.pdf")

        let warning = try #require(OutputFidelityWarning.bookmarks(in: [a, b, c]))
        #expect(warning.kind == .bookmarks(total: 5, fileCount: 2))
        let detail = warning.detail(toolTitle: "Merge")
        #expect(detail.contains("2 of these files"))
        #expect(detail.contains("5 bookmarks"))
    }

    @Test func singleFileBookmarkWarningReadsNaturally() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(1, in: dir, named: "a.pdf")
        let warning = try #require(OutputFidelityWarning.bookmarks(in: [a]))
        let detail = warning.detail(toolTitle: "Split")
        #expect(detail.contains("This PDF has 1 bookmark."))
        #expect(!detail.contains("1 bookmarks"))
    }

    // MARK: Interactive forms

    @Test func aPlainPDFRaisesNoFormWarning() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        #expect(OutputFidelityWarning.interactiveForm(at: plain) == nil)
    }

    // MARK: The acknowledgement gate

    @MainActor
    @Test func gateBlocksOnceThenLetsTheRetryThrough() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(kind: .interactiveForm))

        #expect(gate.shouldProceed() == false, "first attempt must raise the confirmation")
        #expect(gate.isConfirming)

        gate.acknowledge()
        #expect(gate.isConfirming == false)
        #expect(gate.shouldProceed(), "the re-entered save must run through")
    }

    @MainActor
    @Test func noWarningMeansNoConfirmation() {
        let gate = OutputFidelityGate()
        #expect(gate.shouldProceed())
        #expect(gate.isConfirming == false)
    }

    /// The acknowledgement is per-warning: loading a different file must re-arm the confirmation, so
    /// accepting flattening once can't silently apply to the next document.
    @MainActor
    @Test func aDifferentWarningReArmsTheConfirmation() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(kind: .interactiveForm))
        _ = gate.shouldProceed()
        gate.acknowledge()
        #expect(gate.shouldProceed())

        gate.update(OutputFidelityWarning(kind: .bookmarks(total: 4, fileCount: 1)))
        #expect(gate.shouldProceed() == false, "a new warning must be confirmed on its own terms")
    }

    /// Re-detecting the SAME warning (a redraw, an unrelated state change) must not re-prompt.
    @MainActor
    @Test func reDetectingTheSameWarningKeepsTheAcknowledgement() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(kind: .interactiveForm))
        _ = gate.shouldProceed()
        gate.acknowledge()

        gate.update(OutputFidelityWarning(kind: .interactiveForm))
        #expect(gate.shouldProceed(), "an identical warning must not re-prompt")
    }

    @MainActor
    @Test func clearingTheFileClearsTheWarning() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(kind: .interactiveForm))
        gate.update(nil)
        #expect(gate.warning == nil)
        #expect(gate.shouldProceed())
    }
}
