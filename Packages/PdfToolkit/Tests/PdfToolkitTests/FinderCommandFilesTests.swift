import Testing
import Foundation
@testable import PdfToolkit

/// The Finder-extension ↔ helper command-file protocol's pure decisions. These rules used to live
/// inline in two untestable app targets; a regression in ordering or staleness here silently eats
/// user right-clicks, which is exactly the failure the queue redesign exists to prevent.
@Suite struct FinderCommandFilesTests {

    // MARK: Naming

    @Test func fileNameSortsChronologicallyAndSurvivesAbsurdClocks() {
        let earlier = FinderCommandFiles.fileName(now: Date(timeIntervalSince1970: 1_000_000), uuid: UUID())
        let later = FinderCommandFiles.fileName(now: Date(timeIntervalSince1970: 2_000_000), uuid: UUID())
        #expect(earlier < later)                       // lexicographic == chronological
        #expect(earlier.hasPrefix("command-"))
        #expect(earlier.hasSuffix(".json"))
        // A pre-1970 clock clamps to zero instead of trapping the UInt64 conversion mid-right-click.
        let prehistoric = FinderCommandFiles.fileName(now: Date(timeIntervalSince1970: -1), uuid: UUID())
        #expect(prehistoric.hasPrefix("command-0-"))
    }

    // MARK: Draining order

    @Test func pendingOrderPutsLegacyFirstThenChronological() {
        let names = [
            "command-0002000000000-B.json",
            "diag.log",                                    // unrelated container files are ignored
            "command.json",                                // legacy mailbox drains first
            "command-0001000000000-A.json",
            ".command-0003000000000-C.json.sb-1a2b3c",     // Foundation .atomic temp: never drained
            "command-0003000000000-C.jsonx",               // wrong suffix: ignored
        ]
        #expect(FinderCommandFiles.pendingOrder(among: names) == [
            "command.json",
            "command-0001000000000-A.json",
            "command-0002000000000-B.json",
        ])
    }

    @Test func pendingOrderIsEmptyForAnEmptyOrJunkOnlyDirectory() {
        #expect(FinderCommandFiles.pendingOrder(among: []) == [])
        #expect(FinderCommandFiles.pendingOrder(among: ["diag.log", "notes.txt"]) == [])
    }

    // MARK: Staleness

    @Test func stalenessDropsOldMissingAndGarbledTimestamps() {
        let now = Date(timeIntervalSince1970: 10_000)
        // Fresh runs; exactly at the cutoff still runs (strict >); one past it is dropped.
        #expect(!FinderCommandFiles.isStale(ts: now.timeIntervalSince1970 - 5, now: now))
        #expect(!FinderCommandFiles.isStale(ts: now.timeIntervalSince1970 - FinderCommandFiles.maxAge, now: now))
        #expect(FinderCommandFiles.isStale(ts: now.timeIntervalSince1970 - FinderCommandFiles.maxAge - 1, now: now))
        // A backward clock step (negative age) runs — lenient in the direction that can't replay.
        #expect(!FinderCommandFiles.isStale(ts: now.timeIntervalSince1970 + 60, now: now))
        // Missing or non-numeric ts is stale: every extension format writes it, so its absence
        // means a file nobody just created — the replay the cutoff exists to stop.
        #expect(FinderCommandFiles.isStale(ts: nil, now: now))
        #expect(FinderCommandFiles.isStale(ts: "yesterday", now: now))
    }
}
