import Testing
import Foundation
@testable import PdfToolkit

struct ActivityLogFilterTests {
    private func entry(_ level: LogLevel, _ message: String, at t: TimeInterval) -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: t), level: level, message: message)
    }

    @Test func thresholdKeepsAtOrAboveLevel() {
        let entries = [
            entry(.debug, "d", at: 1),
            entry(.info, "i", at: 2),
            entry(.warning, "w", at: 3),
            entry(.error, "e", at: 4),
        ]
        let kept = ActivityLogFilter.matches(entries, minimumLevel: .warning, search: "")
        #expect(kept.map(\.level) == [.warning, .error])
    }

    @Test func nilThresholdKeepsEveryLevel() {
        let entries = [entry(.debug, "d", at: 1), entry(.error, "e", at: 2)]
        #expect(ActivityLogFilter.matches(entries, minimumLevel: nil, search: "").count == 2)
    }

    @Test func searchIsCaseInsensitiveSubstring() {
        let entries = [entry(.info, "Merged files", at: 1), entry(.info, "Rotated pages", at: 2)]
        let kept = ActivityLogFilter.matches(entries, minimumLevel: nil, search: "merge")
        #expect(kept.count == 1)
        #expect(kept.first?.message == "Merged files")
    }

    @Test func applyIsNewestFirst() {
        let entries = [entry(.info, "old", at: 1), entry(.info, "new", at: 2)]
        let ordered = ActivityLogFilter.apply(entries, minimumLevel: nil, search: "")
        #expect(ordered.map(\.message) == ["new", "old"])
    }

    @Test func historyKeepsOnlyOlderNewestFirst() {
        let boundary = Date(timeIntervalSince1970: 100)
        let text = [
            entry(.info, "older1", at: 50),
            entry(.info, "older2", at: 60),
            entry(.info, "current", at: 150),
        ].map(\.formattedString).joined(separator: "\n")
        let history = ActivityLogHistory.parseOlderThan(boundary, text: text)
        #expect(history.map(\.message) == ["older2", "older1"])
    }

    /// Regression: the live mirror is seeded with the previous run's tail, so "Show older history"
    /// must not re-list lines already visible. Lines whose canonical form is in `shown` are dropped.
    @Test func historyExcludesLinesAlreadyShown() throws {
        let boundary = Date(timeIntervalSince1970: 100)
        let older1 = entry(.info, "older1", at: 50)
        let older2 = entry(.info, "older2", at: 60)
        let text = [older1, older2, entry(.info, "current", at: 150)]
            .map(\.formattedString).joined(separator: "\n")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.write(to: url, atomically: true, encoding: .utf8)

        // older1 is already on screen (seeded into the live mirror) -> excluded from history.
        let shown: Set<String> = [older1.formattedString]
        let history = ActivityLogHistory.loadOlderThan(boundary, excluding: shown, fileURL: url)
        #expect(history.map(\.message) == ["older2"])

        // With nothing excluded, both older lines come back (newest-first).
        let full = ActivityLogHistory.loadOlderThan(boundary, excluding: [], fileURL: url)
        #expect(full.map(\.message) == ["older2", "older1"])
    }
}
