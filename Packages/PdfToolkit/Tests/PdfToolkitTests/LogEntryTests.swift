import Testing
import Foundation
@testable import PdfToolkit

struct LogEntryTests {
    @Test func formatParseRoundTrip() {
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123),
            level: .warning,
            message: "Something happened"
        )
        let line = entry.formattedString
        let parsed = LogEntry.parse(line)
        #expect(parsed != nil)
        #expect(parsed?.level == .warning)
        #expect(parsed?.message == "Something happened")
        // Re-rendering the parsed entry reproduces the original line byte for byte.
        #expect(parsed?.formattedString == line)
    }

    @Test func sanitizesControlCharactersToOneLine() {
        let entry = LogEntry(level: .info, message: "line one\nline two\ttabbed")
        #expect(!entry.message.contains("\n"))
        #expect(!entry.message.contains("\t"))
        #expect(!entry.formattedString.contains("\n"))
        // Still round-trips to exactly one entry.
        #expect(LogEntry.parse(entry.formattedString) != nil)
    }

    @Test func parseRejectsMalformedLines() {
        #expect(LogEntry.parse("") == nil)
        #expect(LogEntry.parse("not a log line") == nil)
        #expect(LogEntry.parse("[2024-01-01 00:00:00.000] [BOGUS] hi") == nil)
    }

    @Test func craftedMarkersStayInMessage() {
        // A message that itself embeds "] [" must not forge a second entry — it lands wholly in
        // `message`, and only the FIRST timestamp/level markers are consumed.
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .error,
            message: "weird] [INFO] injected"
        )
        let parsed = LogEntry.parse(entry.formattedString)
        #expect(parsed?.level == .error)
        #expect(parsed?.message == "weird] [INFO] injected")
    }

    @Test func locationTailSplitsForWarningsOnly() {
        let withTail = LogEntry(level: .error, message: "Boom | Location: File.swift:12 / run()")
        #expect(withTail.messageBody == "Boom")
        #expect(withTail.messageLocation == "File.swift:12 / run()")

        // info never carries a location tail, so an info message that happens to contain the marker
        // is shown whole.
        let info = LogEntry(level: .info, message: "note | Location: not-a-tail")
        #expect(info.messageLocation == nil)
        #expect(info.messageBody == "note | Location: not-a-tail")
    }
}
