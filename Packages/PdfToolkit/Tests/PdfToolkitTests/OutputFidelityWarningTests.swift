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
        #expect(OutputFidelityWarning.detect(in: [plain], formLoss: nil, checksBookmarks: true) == nil)
    }

    @Test func bookmarkWarningTotalsAcrossOnlyTheFilesThatHaveThem() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(3, in: dir, named: "a.pdf")
        let b = try pdfWithBookmarks(0, in: dir, named: "b.pdf")
        let c = try pdfWithBookmarks(2, in: dir, named: "c.pdf")

        let warning = try #require(OutputFidelityWarning.detect(in: [a, b, c], formLoss: nil, checksBookmarks: true))
        #expect(warning.losses == [.bookmarks(total: 5, fileCount: 2)])
        let detail = warning.detail(toolTitle: "Merge")
        #expect(detail.contains("2 of these files"))
        #expect(detail.contains("5 bookmarks"))
    }

    @Test func singleFileBookmarkWarningReadsNaturally() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(1, in: dir, named: "a.pdf")
        let warning = try #require(OutputFidelityWarning.detect(in: [a], formLoss: nil, checksBookmarks: true))
        let detail = warning.detail(toolTitle: "Split")
        #expect(detail.contains("This PDF has 1 bookmark,"))
        #expect(!detail.contains("1 bookmarks"))
    }

    // MARK: Interactive forms

    @Test func aPlainPDFRaisesNoFormWarning() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        #expect(OutputFidelityWarning.detect(in: [plain], formLoss: .formFlattened, checksBookmarks: false) == nil)
    }

    // MARK: The acknowledgement gate

    @MainActor
    @Test func gateBlocksOnceThenLetsTheRetryThrough() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(losses: [.formFlattened]))

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
        gate.update(OutputFidelityWarning(losses: [.formFlattened]))
        _ = gate.shouldProceed()
        gate.acknowledge()
        #expect(gate.shouldProceed())

        gate.update(OutputFidelityWarning(losses: [.bookmarks(total: 4, fileCount: 1)]))
        #expect(gate.shouldProceed() == false, "a new warning must be confirmed on its own terms")
    }

    /// Re-detecting the SAME warning (a redraw, an unrelated state change) must not re-prompt.
    @MainActor
    @Test func reDetectingTheSameWarningKeepsTheAcknowledgement() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(losses: [.formFlattened]))
        _ = gate.shouldProceed()
        gate.acknowledge()

        gate.update(OutputFidelityWarning(losses: [.formFlattened]))
        #expect(gate.shouldProceed(), "an identical warning must not re-prompt")
    }

    // MARK: The click-beats-detection race

    /// Detection runs on the shared PDF queue, so a user who drops a file and immediately hits Save
    /// used to beat it: `warning` was still nil, the gate waved the save through, and the
    /// confirmation never appeared. `settle()` closes that window.
    @MainActor
    @Test func settleMakesAFastClickSeeTheWarning() async throws {
        let dir = FixtureDir()
        let form = dir.url("form.pdf")
        try PDFFixtures.writeAcroFormPDF(to: form)

        let gate = OutputFidelityGate()
        // Kick detection off WITHOUT awaiting it — exactly what `.task` does before the user clicks.
        let detection = Task {
            await gate.refresh(urls: [form], formLoss: .formOrphaned, checksBookmarks: false)
        }
        // Let that task actually begin, so this models "detection is in flight when the click
        // lands" rather than racing the runtime's scheduling.
        while !gate.detectionHasStarted { await Task.yield() }

        // The click arrives mid-detection: settle, then decide.
        await gate.settle()
        #expect(gate.isSettling == false, "the spinner state must not be left on")
        #expect(gate.warning != nil, "settle must not return before detection has published")
        #expect(gate.shouldProceed() == false, "the save must be gated, not waved through")
        _ = await detection.value
    }

    /// The spinner is for a click that genuinely has to wait. When detection already finished,
    /// settling is a no-op and the button never flickers.
    @MainActor
    @Test func settleIsANoOpOnceDetectionHasFinished() async throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)

        let gate = OutputFidelityGate()
        await gate.refresh(urls: [plain], formLoss: .formOrphaned, checksBookmarks: true)
        await gate.settle()
        #expect(gate.isSettling == false)
        #expect(gate.warning == nil)
        #expect(gate.shouldProceed(), "a file with nothing to lose still saves straight through")
    }

    /// Switching files must leave the gate describing the file now loaded, not the previous one —
    /// otherwise a user who swaps a form PDF for a plain one keeps being warned about a form that
    /// is no longer open (or, worse, stops being warned about one that is).
    @MainActor
    @Test func switchingFilesRepointsTheWarning() async throws {
        let dir = FixtureDir()
        let form = dir.url("form.pdf")
        try PDFFixtures.writeAcroFormPDF(to: form)
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)

        let gate = OutputFidelityGate()
        await gate.refresh(urls: [form], formLoss: .formOrphaned, checksBookmarks: false)
        #expect(gate.warning?.losses == [.formOrphaned])

        await gate.refresh(urls: [plain], formLoss: .formOrphaned, checksBookmarks: false)
        await gate.settle()
        #expect(gate.warning == nil, "the previous file's warning must not linger")
        #expect(gate.shouldProceed())
    }

    @MainActor
    @Test func clearingTheFileClearsTheWarning() {
        let gate = OutputFidelityGate()
        gate.update(OutputFidelityWarning(losses: [.formFlattened]))
        gate.update(nil)
        #expect(gate.warning == nil)
        #expect(gate.shouldProceed())
    }
}
