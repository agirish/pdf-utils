import Testing
import Foundation
@testable import PdfToolkit

/// Day grouping for the Activity Log viewer: consecutive same-day entries fold into one section
/// with a "Today" / "Yesterday" / formatted-date header. Entries arrive in newest-first display
/// order, so day boundaries are contiguous. Headers are anchored to the real calendar day (the
/// production behavior), so fixtures are built relative to today's noon to dodge midnight edges.
@Suite struct ActivityLogGroupingTests {

    private var todayNoon: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600) }

    private func entry(_ date: Date, _ message: String) -> LogEntry {
        LogEntry(timestamp: date, level: .info, message: message)
    }

    @Test func foldsSameDayEntriesIntoOneSectionPreservingOrder() {
        let entries = [
            entry(todayNoon.addingTimeInterval(3600), "newer"),
            entry(todayNoon, "older"),
        ]
        let sections = ActivityLogGrouping.byDay(entries)
        #expect(sections.count == 1)
        #expect(sections[0].header == "Today")
        #expect(sections[0].items.map(\.message) == ["newer", "older"])
    }

    @Test func splitsAcrossDaysWithTodayAndYesterdayHeaders() {
        let entries = [
            entry(todayNoon, "today entry"),
            entry(todayNoon.addingTimeInterval(-24 * 3600), "yesterday entry"),
        ]
        let sections = ActivityLogGrouping.byDay(entries)
        #expect(sections.map(\.header) == ["Today", "Yesterday"])
        #expect(sections.map { $0.items.count } == [1, 1])
    }

    @Test func olderDaysGetAFormattedDateHeaderNotTodayOrYesterday() {
        let tenDaysAgo = todayNoon.addingTimeInterval(-10 * 24 * 3600)
        let sections = ActivityLogGrouping.byDay([entry(tenDaysAgo, "ancient")])
        #expect(sections.count == 1)
        let header = sections[0].header
        #expect(!header.isEmpty)
        #expect(header != "Today")
        #expect(header != "Yesterday")
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(ActivityLogGrouping.byDay([]).isEmpty)
    }
}
