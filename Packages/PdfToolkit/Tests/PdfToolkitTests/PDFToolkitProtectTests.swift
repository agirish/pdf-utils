import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Encrypt sets one password as both the user and owner password; Remove strips a password from a
/// file you can already open. The headline behavior — and a real past bug — is that Remove's output
/// must open with NO password, which PDFKit only guarantees when the pages are rebuilt into a fresh,
/// unencrypted document. These tests pin that, plus the lock/incorrect/not-encrypted paths.
@Suite struct PDFToolkitProtectTests {

    /// Writes a plain source and an encrypted copy of it locked with `password`.
    private func makeLocked(_ dir: FixtureDir, password: String, pages: Int = 2) throws -> (plain: URL, locked: URL) {
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: pages, to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: password)
        return (plain, locked)
    }

    // MARK: Encrypt

    @Test func encryptProducesAFileThatRequiresThePasswordToOpen() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir, password: "secret")

        let doc = try #require(PDFDocument(url: locked))
        #expect(doc.isEncrypted)
        #expect(doc.isLocked)                              // sealed until unlocked
        #expect(doc.unlock(withPassword: "secret"))        // the chosen password opens it
        #expect(doc.pageCount == 2)
    }

    @Test func encryptRejectsAnEmptyPassword() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.encrypt(inputURL: src, outputURL: dir.url("out.pdf"), password: "")
        }?.kind == "passwordRequired")
    }

    @Test func encryptingAnAlreadyLockedFileThrowsEncryptedInput() throws {
        // The engine refuses to double-encrypt a locked input (it can't read the pages to re-seal).
        // `encryptedInput`, not `incorrectPassword`: no password was entered on this path, so the
        // old "check it and try again" message pointed at a field that doesn't exist.
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir, password: "secret")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.encrypt(inputURL: locked, outputURL: dir.url("out.pdf"), password: "again")
        }?.kind == "encryptedInput")
    }

    @Test func encryptUnreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.encrypt(inputURL: bad, outputURL: dir.url("out.pdf"), password: "x")
        }?.kind == "couldNotOpen")
    }

    // MARK: Remove password

    @Test func removePasswordOutputOpensWithNoPassword() throws {
        // The core guarantee: after removal the output is genuinely unencrypted — not merely the
        // same document with its lock carried along (the bug the engine's rebuild step fixes).
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir, password: "secret")
        let out = dir.url("out.pdf")

        try PDFToolkit.removePassword(inputURL: locked, outputURL: out, password: "secret")

        let doc = try #require(PDFDocument(url: out))
        #expect(!doc.isEncrypted)
        #expect(!doc.isLocked)
        #expect(doc.pageCount == 2)
    }

    @Test func removePasswordPreservesPageContent() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["KEEP1", "KEEP2"], to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "pw")

        try PDFToolkit.removePassword(inputURL: locked, outputURL: out, password: "pw")

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("KEEP1"))
        #expect(texts[1].contains("KEEP2"))
    }

    @Test func removePasswordWithWrongPasswordThrowsIncorrectPassword() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir, password: "secret")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.removePassword(inputURL: locked, outputURL: dir.url("out.pdf"), password: "wrong")
        }?.kind == "incorrectPassword")
    }

    @Test func removePasswordOnAnUnencryptedFileThrowsNotEncrypted() throws {
        // There's nothing to strip from a plain PDF — the tool says so rather than silently copying.
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: plain)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.removePassword(inputURL: plain, outputURL: dir.url("out.pdf"), password: "")
        }?.kind == "notEncrypted")
    }

    @Test func removePasswordCarriesTheInfoDictionaryIntoTheDecryptedCopy() throws {
        // The rebuild that sheds encryption must not shed the document info with it.
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: plain)
        let doc = try #require(PDFDocument(url: plain))
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quarterly Report",
            PDFDocumentAttribute.authorAttribute: "A. Author",
        ]
        let titled = dir.url("titled.pdf")
        #expect(doc.write(to: titled))

        let locked = dir.url("locked.pdf")
        try PDFToolkit.encrypt(inputURL: titled, outputURL: locked, password: "pw")
        let unlocked = dir.url("unlocked.pdf")
        try PDFToolkit.removePassword(inputURL: locked, outputURL: unlocked, password: "pw")

        let out = try #require(PDFDocument(url: unlocked))
        #expect(out.isEncrypted == false)
        #expect(out.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Report")
        #expect(out.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "A. Author")
    }
}
