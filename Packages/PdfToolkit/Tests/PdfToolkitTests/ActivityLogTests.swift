import Testing
import Foundation
@testable import PdfToolkit

@MainActor
struct ActivityLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfutils-log-\(UUID().uuidString).log")
    }

    /// Appends straight to the file via a fresh handle — stands in for another process (the helper).
    private func appendExternally(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func minimumLevelDropsBelowThreshold() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.minimumLevel = .warning
        // The gate returns whether the entry passed — sub-threshold entries are dropped.
        #expect(log.info("dropped") == false)
        #expect(log.debug("dropped") == false)
        #expect(log.warning("kept") == true)
        #expect(log.error("kept") == true)
        log.flushToDisk()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
    }

    @Test func recordSavedEmitsUniformInfoLine() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.recordSaved("Merge", to: URL(fileURLWithPath: "/tmp/out.pdf"), bytes: 2048, detail: "3 files")
        log.flushToDisk()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(contents.contains("[INFO]"))
        #expect(contents.contains("Merge:"))
        #expect(contents.contains("3 files"))
        #expect(contents.contains("out.pdf"))
    }

    @Test func recordSavedAttachesStructuredPath() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.recordSaved("Split", to: URL(fileURLWithPath: "/tmp/out"), bytes: nil, detail: "3 files")

        // The mirror drains on the main queue; yield until the entry lands.
        for _ in 0..<50 where log.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.last?.path == "/tmp/out")
        // A plain log line never records a path, so only real saves surface row actions.
        log.info("no path here")
        for _ in 0..<50 where log.entries.last?.message != "no path here" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.last?.path == nil)
    }

    @Test func liveTailImportsAnotherProcesssAppends() async throws {
        // A separate FileHandle writing straight to the file stands in for the menu-bar helper. With
        // the viewer tailing, its line should surface in `entries` without a relaunch.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Seed so the tailer anchors past existing content (like a launch with prior history).
        try "[2026-01-01 00:00:00.000] [INFO] seed\n".write(to: url, atomically: true, encoding: .utf8)
        let log = ActivityLog(fileURL: url)
        log.beginLiveTailing()

        let external = "[2026-01-01 00:00:01.000] [INFO] Compress PDF: saved → /tmp/x.pdf (1 KB)\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(external.utf8))
        try handle.close()

        for _ in 0..<300 where !log.entries.contains(where: { $0.message.hasPrefix("Compress PDF") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.contains(where: { $0.message.hasPrefix("Compress PDF") }))
        // Tailed-from-disk entries carry no structured path (same as reloaded history).
        #expect(log.entries.first { $0.message.hasPrefix("Compress PDF") }?.path == nil)
    }

    @Test func liveTailCatchesUpOnLinesWrittenBeforeTheFirstOpen() async throws {
        // The helper can log between this process's launch and the viewer's first open. Anchoring
        // the tailer at the current EOF stranded those lines completely: not in the seed (written
        // after it), not tailed (below the anchor), and excluded from "Show older history" (their
        // timestamps are ≥ sessionStart). The tailer must anchor at the seed offset and catch up.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "[2026-01-01 00:00:00.000] [INFO] seed\n".write(to: url, atomically: true, encoding: .utf8)
        let log = ActivityLog(fileURL: url)

        // Written after launch (the seed load) but before beginLiveTailing — the gap window.
        try appendExternally("[2026-01-01 00:00:01.000] [INFO] Compress PDF: pre-open → /tmp/x.pdf (1 KB)\n", to: url)
        log.beginLiveTailing()

        for _ in 0..<300 where !log.entries.contains(where: { $0.message.hasPrefix("Compress PDF") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.contains(where: { $0.message.hasPrefix("Compress PDF") }))
        // The seed itself must not have been re-imported by the catch-up read.
        #expect(log.entries.filter { $0.message == "seed" }.count == 1)
    }

    @Test func tailedEntriesInsertInTimestampOrder() async throws {
        // A tailed line can be older than entries this process logged while the helper's write was
        // in flight. Blind appending put it after newer rows — misordered, and across midnight the
        // day-grouping then emitted duplicate section IDs. It must merge by timestamp.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.beginLiveTailing()

        log.info("own-newer") // stamped with the real (2026) clock
        for _ in 0..<300 where !log.entries.contains(where: { $0.message == "own-newer" }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        try appendExternally("[2026-01-01 00:00:00.000] [INFO] external-older\n", to: url)
        for _ in 0..<300 where !log.entries.contains(where: { $0.message == "external-older" }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let older = try #require(log.entries.firstIndex { $0.message == "external-older" })
        let newer = try #require(log.entries.firstIndex { $0.message == "own-newer" })
        #expect(older < newer)
    }

    @Test func liveTailDoesNotDoubleThisProcesssOwnWrites() async throws {
        // With tailing on, our own write reaches `entries` via the synchronous handoff AND lands on
        // disk where the tailer reads it back. The ledger must make the tailer skip it, not double it.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.beginLiveTailing()
        log.info("only once")

        for _ in 0..<300 where !log.entries.contains(where: { $0.message == "only once" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Give the file tailer ample time to (wrongly) re-import it before asserting.
        try await Task.sleep(for: .milliseconds(250))
        #expect(log.entries.filter { $0.message == "only once" }.count == 1)
    }

    @Test func ownLineLedgerConsumesEachRegistrationOnce() {
        let ledger = OwnLineLedger(capacity: 4)
        ledger.register("a")
        ledger.register("a")       // two identical lines → two skips
        ledger.register("b")
        #expect(ledger.consume("a") == true)
        #expect(ledger.consume("a") == true)
        #expect(ledger.consume("a") == false)   // only two were registered
        #expect(ledger.consume("b") == true)
        #expect(ledger.consume("c") == false)   // never registered
    }

    @Test func ownLineLedgerEvictsOldestBeyondCapacity() {
        // An un-tailed process (the helper) keeps registering; the FIFO must drop the oldest so it
        // stays bounded. Past capacity, the earliest lines are gone and no longer match.
        let ledger = OwnLineLedger(capacity: 2)
        ledger.register("first")
        ledger.register("second")
        ledger.register("third")   // evicts "first"
        #expect(ledger.consume("first") == false)
        #expect(ledger.consume("second") == true)
        #expect(ledger.consume("third") == true)
    }

    @Test func liveTailSurvivesAtomicFileReplacement() async throws {
        // Regression for the reopen bug: the >5 MB trim rewrites the log with an atomic rename, which
        // swaps the inode out from under the tailer's descriptor. The tailer must re-establish its
        // watch on the new file and keep importing. (Before the fd-ownership fix, the reopen closed
        // the new descriptor and live-tailing silently died after the first trim.)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "[2026-01-01 00:00:00.000] [INFO] seed\n".write(to: url, atomically: true, encoding: .utf8)
        let log = ActivityLog(fileURL: url)
        log.beginLiveTailing()

        try appendExternally("[2026-01-01 00:00:01.000] [INFO] Merge PDF: before → /tmp/a.pdf (1 KB)\n", to: url)
        for _ in 0..<300 where !log.entries.contains(where: { $0.message.contains("before") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.contains(where: { $0.message.contains("before") }))

        // Atomic replace = write-temp-then-rename, exactly what the trim does; fires delete/rename.
        try Data("[2026-01-01 00:00:02.000] [INFO] trimmed-tail\n".utf8).write(to: url, options: .atomic)
        // Let the tailer process the delete/rename and re-arm on the new inode before appending, so we
        // test post-reopen liveness rather than the (accepted) trim-boundary skip.
        try await Task.sleep(for: .milliseconds(300))

        try appendExternally("[2026-01-01 00:00:03.000] [INFO] Compress PDF: after → /tmp/b.pdf (2 KB)\n", to: url)
        for _ in 0..<300 where !log.entries.contains(where: { $0.message.contains("after") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.contains(where: { $0.message.contains("after") }))
    }

    @Test func liveTailAnchorsAtOpenSoManyPreWindowOwnWritesNeverDouble() async throws {
        // Regression for the ledger-overflow doubling: log more own lines than the dedup ledger's
        // capacity BEFORE opening the viewer. Anchoring the tailer at the file's end on open means
        // those lines sit below the read offset and are never re-read, so none double even though most
        // were evicted from the ledger. (Anchoring at launch would re-import the evicted ones.)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        for i in 0..<1200 { log.info("pre-\(i)") }   // > ownLines capacity (1000)
        log.flushToDisk()
        for _ in 0..<400 where log.entries.count < 1000 { try await Task.sleep(for: .milliseconds(10)) }

        log.beginLiveTailing()
        try await Task.sleep(for: .milliseconds(300))   // ample time for a (wrong) re-import

        let perMessage = Dictionary(grouping: log.entries, by: \.message).mapValues(\.count)
        #expect(perMessage.values.allSatisfy { $0 == 1 })   // nothing doubled
        #expect(log.entries.count <= 1000)                  // mirror stayed capped, no re-import flood
    }

    @Test func historyLineParsesWithoutPath() {
        // A save's structured path is deliberately absent from the on-disk line, so an entry
        // reconstructed from history carries no path (and thus offers no Reveal/Open actions).
        let saved = LogEntry(level: .info, message: "Split: 3 files → ~/out", path: "/tmp/out")
        let reparsed = LogEntry.parse(saved.formattedString)
        #expect(reparsed != nil)
        #expect(reparsed?.path == nil)
        // The path never leaks into the canonical rendering either.
        #expect(!saved.formattedString.contains("/tmp/out"))
    }

    @Test func clearEmptiesMemoryAndFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.info("something")
        log.flushToDisk()
        log.clearLogs()
        log.flushToDisk()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(contents.isEmpty)
    }

    @Test func entryLoggedAfterClearSurvivesBothDestinations() async throws {
        // Pins the sequential contract around clearing: an entry logged after the clear reaches
        // both destinations and the pre-clear entry resurrects in neither. (The preemption race the
        // queue-ordered purge fixes — a background log() suspended between its disk append and its
        // buffer handoff — cannot be induced deterministically from a test; this guards the
        // surrounding behavior the fix must not break.)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)
        log.info("before-clear")
        log.flushToDisk()
        log.clearLogs()
        log.info("after-clear")
        log.flushToDisk()

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!contents.contains("before-clear"))
        #expect(contents.contains("after-clear"))

        // The mirror drains on the main queue; yield until it catches up.
        for _ in 0..<50 where !log.entries.contains(where: { $0.message == "after-clear" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.entries.map(\.message) == ["after-clear"])
    }
}
