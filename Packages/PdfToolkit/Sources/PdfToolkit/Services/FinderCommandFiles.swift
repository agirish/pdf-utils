import Foundation

/// The pure decisions of the Finder-extension → helper command-file protocol, shared by both
/// processes so the naming, draining order, and staleness rules have one definition — and tests.
/// (They previously lived inline in two untestable app targets; this package's convention is to
/// extract exactly such logic, per PageRangeParser and selectBestAttempt.)
public enum FinderCommandFiles {
    /// Requests older than this are dropped (still deleted): a stale file means the helper died
    /// between the extension's write and processing, and executing it at the next login — hours or
    /// days later, with no user action — is worse than losing it. A live ping arrives in seconds.
    public static let maxAge: TimeInterval = 5 * 60

    /// The shared mailbox name pre-queue extensions write; drained first for an old extension
    /// instance Finder hasn't reloaded yet.
    public static let legacyName = "command.json"

    /// One file per request. The millisecond prefix makes lexicographic order request order
    /// (13 digits until the year 2286); the UUID de-collides same-millisecond requests. The clamp
    /// keeps a pre-1970 system clock from trapping the UInt64 conversion in the extension.
    public static func fileName(now: Date = Date(), uuid: UUID = UUID()) -> String {
        "command-\(UInt64(max(0, now.timeIntervalSince1970) * 1000))-\(uuid.uuidString).json"
    }

    /// The queued request names among `names`, in processing order: legacy first, then per-request
    /// files chronologically. Foundation's `.atomic` temp names (`<name>.json.sb-…`) can never
    /// match the `.json` suffix test, so a mid-write file is never drained.
    public static func pendingOrder(among names: [String]) -> [String] {
        let queued = names
            .filter { $0.hasPrefix("command-") && $0.hasSuffix(".json") }
            .sorted()
        let legacy = names.contains(legacyName) ? [legacyName] : []
        return legacy + queued
    }

    /// Whether a request is too old to run. A missing or non-numeric timestamp is stale too:
    /// every extension format writes `ts`, so its absence means a hand-crafted or corrupt file —
    /// and the cutoff exists precisely so a request nobody just made never runs. A negative age
    /// (clock stepped backward between write and drain) runs: lenient in the direction that can't
    /// replay something old.
    public static func isStale(ts: Any?, now: Date = Date()) -> Bool {
        guard let ts = ts as? TimeInterval else { return true }
        return now.timeIntervalSince1970 - ts > maxAge
    }
}
