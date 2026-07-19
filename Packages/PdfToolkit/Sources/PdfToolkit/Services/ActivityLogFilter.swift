import Foundation

/// Pure filtering for the Activity Log, kept out of the view so the level threshold, case-insensitive
/// message search, and newest-first ordering are unit-testable without any `@State`. Ported from
/// SyncCloud's `LogEntryFilter` (minus the `level:`/`since:` token grammar).
public enum ActivityLogFilter {
    /// Keeps entries at or above `minimumLevel` (a severity *threshold*, not exact-match) whose
    /// message contains `search` (case-insensitive), preserving input order. `minimumLevel == nil`
    /// shows every level; an empty/whitespace `search` matches everything.
    ///
    /// Threshold, not equality, is the point: someone opening the log after a failure wants
    /// "warnings and errors", which exact-match could never express.
    public static func matches(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String) -> [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let minimumLevel, entry.level.severity < minimumLevel.severity { return false }
            if needle.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(needle)
        }
    }

    /// ``matches(_:minimumLevel:search:)`` newest-first — the list's order (entries are stored
    /// oldest-first, as logged).
    public static func apply(_ entries: [LogEntry], minimumLevel: LogLevel?, search: String) -> [LogEntry] {
        matches(entries, minimumLevel: minimumLevel, search: search).reversed()
    }
}

/// Loads previous-session history from the on-disk log so the viewer can show entries that predate
/// the current launch. Pure/`static` so the read+parse runs off the main actor and stays testable.
/// Ported from SyncCloud's `LogHistoryLoader`.
public enum ActivityLogHistory {
    /// Every entry in `fileURL` strictly older than `sessionStart` — i.e. everything from earlier
    /// sessions, excluding the current session's lines (already shown live from memory) — newest
    /// first. Lines that don't parse are skipped.
    public static func loadOlderThan(_ sessionStart: Date, fileURL: URL) -> [LogEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parseOlderThan(sessionStart, text: text)
    }

    /// The pure core of ``loadOlderThan(_:fileURL:)``, split out so the parse/boundary/order logic is
    /// testable without touching disk.
    public static func parseOlderThan(_ sessionStart: Date, text: String) -> [LogEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { LogEntry.parse(String($0)) }
            .filter { $0.timestamp < sessionStart }
            .reversed()
    }
}
