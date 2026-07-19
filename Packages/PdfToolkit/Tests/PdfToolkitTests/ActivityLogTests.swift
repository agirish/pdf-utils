import Testing
import Foundation
@testable import PdfToolkit

@MainActor
struct ActivityLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfutils-log-\(UUID().uuidString).log")
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
        // Clearing now purges the handoff buffer on the writer queue, ordered after the truncate —
        // this pins that the purge drops only pre-clear entries: one logged after the clear must
        // reach both the file and the in-memory mirror, and the pre-clear one may never resurrect.
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
