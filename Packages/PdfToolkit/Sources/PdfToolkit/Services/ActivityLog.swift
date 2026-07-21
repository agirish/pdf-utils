import Foundation
import SwiftUI

// MARK: - Log level

/// The severity of an Activity Log entry. Ported from SyncCloud's `Events/Logger` so the two apps'
/// logs read and parse identically. Like SyncCloud, pdf-utils shares its log file across processes —
/// the main app and the menu-bar Helper both write it — so the cross-process trim lock is carried;
/// only SyncCloud's CLI-specific machinery is left out.
public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    /// Informational telemetry — the standard "operation succeeded" event.
    case info = "INFO"
    /// Verbose lifecycle breadcrumbs — e.g. an operation starting — kept below the routine INFO
    /// record and surfaced only at the "Everything" level.
    case debug = "DEBUG"
    /// A non-critical problem that did not halt the operation, or an operation that finished
    /// incompletely (e.g. a batch stopped partway through its queue).
    case warning = "WARN"
    /// A failed operation.
    case error = "ERROR"

    public var id: String { rawValue }

    /// Ordering for the minimum-level gate: entries below `ActivityLog.minimumLevel`'s severity are
    /// dropped. Debug is the lowest so the default gate changes nothing.
    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public var color: Color {
        switch self {
        case .info: return .blue
        case .debug: return .gray
        case .warning: return .orange
        case .error: return .red
        }
    }

    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .debug: return "ant.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Log entry

/// One recorded event. The on-disk and clipboard rendering is `[timestamp] [LEVEL] message`, byte
/// for byte, so `formattedString` and `parse(_:)` round-trip — which is what lets "Show older
/// history" reload prior-session lines from `~/pdf-utils.log`.
public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    /// Absolute filesystem path of the file or folder this entry recorded a write to, populated by
    /// `recordSaved`; nil for every other entry. Kept as a structured field rather than re-parsed out
    /// of `message` so the viewer's Reveal/Open row actions get an exact, unambiguous target. It is
    /// intentionally NOT part of `formattedString`/`parse`, so it stays nil on history lines reloaded
    /// from disk — those simply show no actions.
    public let path: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String, path: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.path = path
        // Collapse line breaks and control characters to spaces so one entry is always one line. A
        // message often interpolates a file/folder name straight off disk, which macOS permits to
        // contain "\n" — an embedded newline would otherwise split the record and let a crafted name
        // forge a second "[timestamp] [ERROR] …" line in the file and the viewer. Enforcing it here
        // covers every call site at once.
        //
        // Uses an explicit control + line-separator set rather than `.controlCharacters` (which is
        // Cc AND Cf): Cf format chars — ZWJ, directional marks, soft hyphen — are legitimate parts
        // of emoji/RTL filenames and don't break the one-line invariant, so collapsing them would
        // needlessly mangle those names.
        self.message = message.components(separatedBy: Self.lineBreakingChars).joined(separator: " ")
    }

    /// C0/C1 controls (incl. tab and ESC — the latter blocks terminal-escape injection when the file
    /// is `cat`-ed) plus every Unicode line separator (U+0085, U+2028, U+2029). Excludes Cf.
    private static let lineBreakingChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{0000}"..."\u{001F}")       // C0 controls (\n \r \t ESC …)
        set.insert("\u{007F}")                                              // DEL
        set.formUnion(CharacterSet(charactersIn: "\u{0080}"..."\u{009F}"))  // C1 controls
        set.formUnion(.newlines)                                            // + U+0085 / U+2028 / U+2029
        return set
    }()

    /// Shared timestamp formatter, reused rather than reallocated per line. Locale/calendar are
    /// pinned (en_US_POSIX + Gregorian) because this formatter also PARSES history lines back out of
    /// the file: under a non-Gregorian system calendar the round-trip would silently mis-date every
    /// parsed entry. The timezone stays local to match the file's existing lines.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// The canonical single-line rendering used for both the disk log and the viewer's Copy action,
    /// so the clipboard matches the file byte for byte.
    public var formattedString: String {
        "[\(Self.timestampFormatter.string(from: timestamp))] [\(level.rawValue)] \(message)"
    }

    /// The inverse of ``formattedString``: reconstructs an entry from one canonical log line so the
    /// viewer can display history that predates the current session. Returns nil for any line that
    /// doesn't match the exact `[timestamp] [LEVEL] ` shape (a blank line, or a partial line left by
    /// a mid-write trim), so a malformed line is skipped, not shown.
    ///
    /// Anchored on the leading `] [` / `] ` markers rather than a fixed offset, and it only ever
    /// consumes the FIRST such markers — the timestamp and level tokens contain neither, so a
    /// message that itself embeds `] [` (a crafted filename) lands wholly in `message` and cannot
    /// forge a second entry. Writes already strip newlines, so one file line is always one entry.
    public static func parse(_ line: String) -> LogEntry? {
        guard line.hasPrefix("["),
              let tsClose = line.range(of: "] ["),
              let levelClose = line.range(of: "] ", range: tsClose.upperBound..<line.endIndex) else {
            return nil
        }
        let timestampText = String(line[line.index(after: line.startIndex)..<tsClose.lowerBound])
        let levelText = String(line[tsClose.upperBound..<levelClose.lowerBound])
        let message = String(line[levelClose.upperBound...])
        guard let level = LogLevel(rawValue: levelText),
              let timestamp = timestampFormatter.date(from: timestampText) else {
            return nil
        }
        return LogEntry(timestamp: timestamp, level: level, message: message)
    }

    /// The developer-oriented `" | Location: file:line / function"` tail that `warning`/`error`
    /// append, split from the human-readable message. The viewer shows `messageBody` prominently and
    /// `messageLocation` as a dimmed caption, so a warning row reads as its message, not a file path.
    public var messageBody: String { messageSplit.body }
    public var messageLocation: String? { messageSplit.location }
    private var messageSplit: (body: String, location: String?) {
        // Only warning/error append the tail; info/debug never do, so their message is shown whole.
        // Split on the LAST occurrence, since the real tail is always last.
        guard level == .warning || level == .error,
              let range = message.range(of: " | Location: ", options: .backwards) else { return (message, nil) }
        return (String(message[..<range.lowerBound]), String(message[range.upperBound...]))
    }
}

// MARK: - Activity log

/// A thread-safe, app-wide log of file-changing operations. Writes each event to `~/pdf-utils.log`
/// and keeps an observable in-memory mirror driving the Activity Log window.
///
/// `@MainActor` because its `@Published entries` drives SwiftUI. The public logging methods are
/// `nonisolated` so any context (a background `fileExporter` callback, a `Task`) can record without
/// hopping actors first: they append to the disk writer synchronously and hand the in-memory
/// insertion to the main actor. Recording never throws and never blocks the operation that produced
/// it — a dropped line costs at most that line, never the file operation.
@MainActor
public final class ActivityLog: ObservableObject {
    /// The shared instance the app records into. Tests build their own against a temp-file URL.
    public static let shared = ActivityLog(fileURL: ActivityLog.defaultFileURL())

    /// Recent entries shown in the viewer, oldest-first (append order), capped at `maxInMemory`.
    /// Older entries still live in the file until trimmed, and load on demand via `ActivityLogHistory`.
    @Published public private(set) var entries: [LogEntry] = []

    /// When this app session started, captured at construction. "Show older history" divides at this
    /// boundary. It must be a FIXED value, not `entries.first` — the mirror is trimmed to the newest
    /// N, so after a busy session `entries.first` would drift into the current session.
    public let sessionStart = Date()

    /// The disk destination. Public so the viewer can reveal it in Finder and open it.
    public let fileURL: URL

    /// Defaults key holding the persisted minimum level (a `LogLevel` raw value). The app seeds
    /// `shared.minimumLevel` from it at launch.
    public static let minimumLevelDefaultsKey = "pdfutils.logMinimumLevel"

    /// The level a fresh install records at: `.info`, so the log reads as a clean record of file
    /// changes (saves) and failures out of the box. Dropping to `.debug` ("Everything" in Settings)
    /// additionally surfaces the operation-lifecycle breadcrumbs. This is the single source of truth
    /// for that default — shared by the launch seed, the Settings picker's initial value, and Reset
    /// All Settings — so the three can't drift apart.
    public static let defaultMinimumLevel: LogLevel = .info

    /// The persisted minimum level, falling back to ``defaultMinimumLevel`` when unset/unrecognized.
    public static func persistedMinimumLevel(from defaults: UserDefaults = .standard) -> LogLevel {
        defaults.string(forKey: minimumLevelDefaultsKey).flatMap(LogLevel.init(rawValue:)) ?? defaultMinimumLevel
    }

    /// Entries below this severity are dropped before memory or disk. Lock-guarded because the
    /// logging methods run on the caller's thread.
    public nonisolated var minimumLevel: LogLevel {
        get { minimumLevelBox.value }
        set { minimumLevelBox.value = newValue }
    }
    private let minimumLevelBox = LockedValue<LogLevel>(ActivityLog.defaultMinimumLevel)

    private static let maxInMemory = 1000

    let writer: LogFileWriter
    /// Ordered handoff from nonisolated loggers to the main actor. `DispatchQueue.main.async`
    /// preserves submission order, so entries land in call order.
    // Internal (not private) so tests can seed a deterministic out-of-order batch and pin that
    // draining goes through the ordered insert — the racing-threads inversion this guards against
    // can't be produced deterministically through the public surface.
    let pending = LockedValue<[LogEntry]>([])

    /// The lines this process has written, recorded so the live tailer can recognize and skip them
    /// when it reads them back off disk — they already reached `entries` through the synchronous
    /// handoff above, so re-importing them would double every self-logged entry. See ``beginLiveTailing()``.
    // Internal (not private) so tests can observe the catch-up suspension window on the ledger.
    let ownLines = OwnLineLedger(capacity: maxInMemory)

    /// The live-tail watcher, created on the first ``beginLiveTailing()``. Stays nil in processes that
    /// never display the log (the menu-bar helper) and until the viewer first opens.
    private var tailer: ActivityLogTailer?

    /// Byte size and inode of the file exactly as the init-time seed load saw it. The first
    /// ``beginLiveTailing()`` anchors at this offset (when safe) so lines appended between launch
    /// and the viewer's first open aren't stranded in a gap — see the discussion there.
    private let seededFileSize: UInt64
    private let seededFileIdentity: UInt64?

    /// Depth of in-flight ``clearLogs()`` purges. While non-zero, ``drainPending()`` leaves the
    /// handoff buffer alone so the writer-queue purge can drop pre-truncate entries — see `clearLogs`.
    private let clearsInFlight = LockedValue<Int>(0)

    init(fileURL: URL) {
        self.fileURL = fileURL
        // Seed BEFORE creating the writer: the writer's init queues an oversize trim, and reading
        // first keeps the seed, its byte count, and the recorded inode all describing one file state.
        let seed = Self.loadRecentSeed(from: fileURL, limit: Self.maxInMemory)
        self.entries = seed.entries
        self.seededFileSize = seed.byteCount
        self.seededFileIdentity = Self.fileIdentity(of: fileURL)
        self.writer = LogFileWriter(url: fileURL)
    }

    /// Byte size of the file at `url`, or 0 when absent/unreadable.
    private static func fileSize(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Inode of the file at `url`, or nil when absent — changes when a trim/clear rewrites the log.
    private static func fileIdentity(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    // MARK: File location

    /// Resolves the disk destination. Mirrors SyncCloud's scheme so test runs never pollute the real
    /// log: `PDFUTILS_LOG_FILE` overrides the path; under any test runner a per-process temp file is
    /// used; otherwise `~/pdf-utils.log`.
    public static func defaultFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PDFUTILS_LOG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
        let isRunningTests = executable == "swiftpm-testing-helper"
            || executable == "xctest"
            || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("pdf-utils-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        }
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        return URL(fileURLWithPath: homeDir).appendingPathComponent("pdf-utils.log")
    }

    // MARK: Logging

    @discardableResult
    public nonisolated func info(_ message: String) -> Bool { log(.info, message) }

    @discardableResult
    public nonisolated func debug(_ message: String) -> Bool { log(.debug, message) }

    @discardableResult
    public nonisolated func warning(_ message: String, file: String = #file, line: Int = #line, function: String = #function) -> Bool {
        log(.warning, "\(message) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)")
    }

    @discardableResult
    public nonisolated func error(_ message: String, file: String = #file, line: Int = #line, function: String = #function) -> Bool {
        log(.error, "\(message) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)")
    }

    /// Records one file save uniformly: `Operation: [detail →] ~/path (size)`. Every save-site calls
    /// this so the log reads consistently regardless of which tool produced the entry.
    public nonisolated func recordSaved(_ operation: String, to url: URL, bytes: Int?, detail: String? = nil) {
        var line = operation + ":"
        if let detail, !detail.isEmpty { line += " \(detail) →" } else { line += " saved →" }
        line += " \((url.path as NSString).abbreviatingWithTildeInPath)"
        if let bytes { line += " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))" }
        // The full path also rides along as a structured field so the viewer can Reveal/Open the
        // destination without re-deriving it from the tilde-abbreviated text in `line`.
        log(.info, line, path: url.path)
    }

    /// The gate + the two destinations. Returns whether the entry passed the level gate (`false` when
    /// dropped) — handy for tests; production ignores it.
    @discardableResult
    private nonisolated func log(_ level: LogLevel, _ message: String, path: String? = nil) -> Bool {
        guard level.severity >= minimumLevel.severity else { return false }
        let entry = LogEntry(level: level, message: message, path: path)
        // Register the line before it hits disk, so by the time the live tailer reads it back the
        // ledger already knows it's ours and skips it — the entry reaches `entries` via the handoff
        // below, and re-importing it from the file would double it.
        ownLines.register(entry.formattedString)
        // The handoff-buffer append rides the writer queue with the disk append: both mutations
        // happen in one ordered domain, so `clearLogs`' queued purge either drops an entry from
        // both destinations or keeps it in both. Mutating `pending` here on the caller's thread
        // let an entry whose bytes the clear truncated from disk still surface in the viewer —
        // a line that then silently vanished on relaunch.
        writer.append(entry.formattedString + "\n") { [weak self] in
            guard let self else { return }
            self.pending.mutate { $0.append(entry) }
            DispatchQueue.main.async { self.drainPending() }
        }
        return true
    }

    func drainPending() {
        // While a clear's truncate is in flight, leave the buffer alone: an entry sitting in
        // `pending` right now had its bytes written BEFORE the truncate (the completion-ordered
        // handoff guarantees that), so the writer-queue purge must be the one to take it. Draining
        // it here surfaced a line in the freshly cleared viewer that silently vanished on relaunch.
        guard clearsInFlight.value == 0 else { return }
        let batch = pending.take()
        guard !batch.isEmpty else { return }
        insertOrdered(batch)
    }

    /// Merges entries into the mirror keeping timestamp order (from the end — the common case is
    /// an in-order append), then applies the memory cap. Every mirror mutation funnels through
    /// here so `entries` is ALWAYS timestamp-sorted: the viewer's day-grouping merges adjacent
    /// same-day runs and emits its `yyyy-MM-dd` key as a `ForEach` ID, so any out-of-order pair
    /// straddling midnight — own lines stamped on racing threads, tailed helper lines, a skewed
    /// seed — would produce duplicate section IDs (undefined SwiftUI behavior).
    ///
    /// At the cap, the oldest entries are dropped — including, deliberately, an incoming entry
    /// older than everything already shown: a 1000-entry-deep mirror's tail is the coherent
    /// "newest window", and re-surfacing an ancient stray in the middle of it would be noise.
    private func insertOrdered(_ newEntries: [LogEntry]) {
        for entry in newEntries {
            var index = entries.endIndex
            while index > entries.startIndex, entries[index - 1].timestamp > entry.timestamp {
                index -= 1
            }
            entries.insert(entry, at: index)
        }
        if entries.count > Self.maxInMemory {
            entries.removeFirst(entries.count - Self.maxInMemory)
        }
    }

    // MARK: Live tail (other processes)

    /// Starts watching the log file for appends made by OTHER processes — the menu-bar helper writing
    /// Finder-triggered runs — and streams them into `entries` so an already-open viewer updates in
    /// real time instead of only on the next launch. Idempotent; the viewer calls it on appear.
    ///
    /// Only external lines are imported: this process's own writes already arrive through the
    /// synchronous handoff and are recognized (and skipped) via `ownLines`, so nothing is doubled.
    /// Externally-tailed entries are parsed from disk and therefore carry no structured `path`, so —
    /// like reloaded history — they offer no Reveal/Open row actions, which is expected.
    ///
    /// The tailer anchors at the offset the init-time seed load reflected, so another process's
    /// lines appended between launch and this first open are caught up on. Anchoring at the current
    /// end instead stranded them completely: they were in neither the seed (written after it) nor
    /// the tail (below the anchor) nor "Show older history" (their timestamps are ≥ `sessionStart`)
    /// — unfindable for the whole session. Own lines in the catch-up window are recognized and
    /// skipped via the ledger. Two cases fall back to anchoring at the current end, forgoing the
    /// catch-up rather than risking damage: the ledger has evicted (1000+ own lines this session —
    /// an evicted own line would re-import as external, doubled and mis-ordered), or the file was
    /// rewritten since launch (inode changed / size shrank: a trim or clear), where the seed offset
    /// no longer addresses the bytes it did at launch.
    public func beginLiveTailing() {
        guard tailer == nil else { return }
        let size = Self.fileSize(of: fileURL)
        // A nil seeded identity means the file did not exist at init — the writer created it just
        // after the (empty) seed, so offset 0 is exactly the seed boundary and the current inode is
        // irrelevant. Requiring identity equality here compared some-inode != nil, always failed,
        // and silently re-stranded the launch-to-open window on every fresh install.
        let identityCompatible = seededFileIdentity == nil
            ? seededFileSize == 0
            : Self.fileIdentity(of: fileURL) == seededFileIdentity
        // Checked-and-suspended in one locked step: a plain hasEvicted read raced registrations
        // landing between this decision and the tailer's catch-up consumes — with the ledger near
        // capacity, a burst could evict lines the catch-up hadn't reached yet and re-import them as
        // external. While suspended, register() never evicts (the ledger may briefly exceed
        // capacity — bounded by the milliseconds until the first read completes); the tailer
        // resumes eviction, trimming back to capacity, right after that read.
        let seedAnchorIsSafe = identityCompatible
            && size >= seededFileSize
            && ownLines.suspendEvictionIfCleanSoFar()
        let tailer = ActivityLogTailer(
            url: fileURL,
            startOffset: seedAnchorIsSafe ? seededFileSize : size,
            ledger: ownLines,
            resumesEvictionAfterFirstRead: seedAnchorIsSafe
        ) { [weak self] external in
            // The tailer delivers on the main thread.
            MainActor.assumeIsolated { self?.appendExternal(external) }
        }
        self.tailer = tailer
        tailer.start()
    }

    /// Merges entries the tailer read from another process's writes into the mirror, via the same
    /// ordered insert as `drainPending` — see `insertOrdered` for why order is an invariant.
    private func appendExternal(_ newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        insertOrdered(newEntries)
    }

    // MARK: Clearing / flushing

    /// Empties the in-memory mirror and the on-disk file. The handoff buffer is dropped twice: once
    /// here (anything already handed off but not yet drained) and once on the writer queue after
    /// the truncate lands (anything a concurrent `log()` appended to disk ahead of the truncate),
    /// so an entry the clear wiped from disk can never resurrect in the viewer.
    public func clearLogs() {
        // Gate main-queue drains until the truncate's purge runs: an append already on the writer
        // queue lands its bytes BEFORE the truncate, and if its main-queue drain won the race
        // against the writer-queue purge, the entry showed in the cleared viewer but its bytes
        // were gone — a ghost line that vanished on relaunch.
        clearsInFlight.mutate { $0 += 1 }
        _ = pending.take()
        entries.removeAll()
        // Re-anchor the tailer to the (about-to-be-)truncated file so it doesn't re-import the lines
        // the clear is wiping. The truncate is queued behind this on the writer; either way the
        // tailer's own shrink check re-anchors it once the file actually shortens.
        tailer?.reanchor()
        writer.clear { [pending, clearsInFlight, weak self] in
            _ = pending.take()
            clearsInFlight.mutate { $0 -= 1 }
            // Kick a drain for entries logged after the clear whose scheduled drain hit the gate.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.drainPending() }
            }
        }
    }

    /// Blocks until every buffered disk write is committed. Called at app termination so an in-flight
    /// operation's breadcrumb survives the quit; tests use it before asserting on file contents.
    public nonisolated func flushToDisk() {
        writer.flush()
    }

    /// Opens the log file in the default text editor (Console/TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: Loading

    /// The newest `limit` entries already on disk, in append (oldest-first) order — so a relaunch
    /// shows the tail of the previous run without waiting for new activity. Returns the byte count
    /// of exactly the data that was parsed, so the first live-tail can anchor with no gap and no
    /// overlap between the seed and the tail.
    private static func loadRecentSeed(from url: URL, limit: Int) -> (entries: [LogEntry], byteCount: UInt64) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ([], 0)
        }
        let parsed = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { LogEntry.parse(String($0)) }
        let recent = parsed.count > limit ? Array(parsed.suffix(limit)) : parsed
        // The newest window is picked by FILE order (append order — true recency), but the kept
        // entries are then stably sorted by timestamp: two processes share this file, and helper
        // clock skew can leave file order ≠ timestamp order, which would break the mirror's
        // sorted-order invariant (see `insertOrdered`) right from the seed. The index tiebreak
        // keeps same-millisecond lines in file order (Swift's sort is not guaranteed stable).
        let sorted = recent.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        return (sorted, UInt64(data.count))
    }
}

// MARK: - Locked value

/// A minimal lock-guarded cell readable/writable from any thread. Used for the level gate and the
/// nonisolated → main-actor handoff buffer, both touched off the main actor by `log()`.
/// Internal (not private) because the test-visible `pending` buffer is typed with it.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ initial: Value) { stored = initial }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&stored); lock.unlock()
    }
}

extension LockedValue where Value: RangeReplaceableCollection {
    /// Returns the current contents and resets to empty in one locked step.
    func take() -> Value {
        lock.lock(); defer { lock.unlock() }
        let current = stored
        stored = Value()
        return current
    }
}

// MARK: - Own-line ledger

/// A bounded record of the log lines THIS process has written but the live tailer may still read back
/// off disk. The tailer consults it to skip re-importing our own entries — they already reached the
/// viewer's `entries` through the synchronous handoff. Bounded FIFO: nothing drains it until a tailer
/// runs (the helper writes but never tails), so it must not grow without bound. Keyed on the exact
/// canonical line, and a multiset so two identical lines (same millisecond + message) each skip once.
final class OwnLineLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var order: [String] = []
    private var evicted = false
    private var evictionSuspended = false
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    /// Whether any registration has ever been evicted. Once true, "not in the ledger" no longer
    /// implies "not ours", so the first live-tail must not catch up on the pre-open window.
    var hasEvicted: Bool {
        lock.lock(); defer { lock.unlock() }
        return evicted
    }

    /// Whether a catch-up window is currently holding eviction open — observable so tests can pin
    /// the begin-tailing wiring (suspend on begin, resume after the first read).
    var isEvictionSuspended: Bool {
        lock.lock(); defer { lock.unlock() }
        return evictionSuspended
    }

    /// One locked step for the catch-up decision: if nothing has ever been evicted, suspends
    /// eviction and returns true; otherwise leaves the ledger untouched and returns false. The
    /// atomicity closes the gap where an eviction between a plain `hasEvicted` read and the
    /// catch-up's consumes could drop a line the read hadn't reached yet.
    func suspendEvictionIfCleanSoFar() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !evicted else { return false }
        evictionSuspended = true
        return true
    }

    /// Ends the catch-up window: trims back down to capacity (marking `evicted` if anything goes)
    /// and re-enables normal eviction.
    func resumeEviction() {
        lock.lock(); defer { lock.unlock() }
        evictionSuspended = false
        trimToCapacityLocked()
    }

    /// Records one written line, evicting the oldest once over capacity so an un-tailed process (the
    /// helper) stays bounded. While suspended (a live-tail catch-up is consuming), the ledger grows
    /// past capacity instead — bounded by the catch-up's duration — so no consumable line vanishes
    /// mid-read.
    func register(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        counts[line, default: 0] += 1
        order.append(line)
        if !evictionSuspended {
            trimToCapacityLocked()
        }
    }

    private func trimToCapacityLocked() {
        while order.count > capacity {
            let dropped = order.removeFirst()
            if let count = counts[dropped] { counts[dropped] = count > 1 ? count - 1 : nil }
            evicted = true
        }
    }

    /// If `line` is one we wrote, consumes one occurrence and returns true (so the tailer skips it).
    func consume(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let count = counts[line], count > 0 else { return false }
        counts[line] = count > 1 ? count - 1 : nil
        if let index = order.firstIndex(of: line) { order.remove(at: index) }
        return true
    }
}

// MARK: - Live tailer

/// Watches the log file for appends by OTHER processes and streams the parsed entries to `onExternal`.
/// A single `DispatchSource` on the file wakes us on every write; we read only the bytes past our last
/// position, skip any line this process itself wrote (via ``OwnLineLedger``), and hand the rest to the
/// callback on the main thread. An atomic replacement — the trim's write-temp-then-rename, which swaps
/// the inode out from under our open descriptor — is detected via the source's delete/rename events
/// and the watch is re-established on the new file. All mutable state is confined to `queue`.
final class ActivityLogTailer: @unchecked Sendable {
    private let url: URL
    private let ledger: OwnLineLedger
    private let onExternal: @Sendable ([LogEntry]) -> Void
    private let queue = DispatchQueue(label: "com.pdfutils.activitylog.tail", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    /// File offset already consumed. Confined to `queue`.
    private var offset: UInt64
    /// Bytes read since the last newline — a line split across two reads is held here until complete.
    private var partial = Data()

    /// When true, the initial read is a seed-anchored catch-up running with ledger eviction
    /// suspended (see `OwnLineLedger.suspendEvictionIfCleanSoFar`); the tailer resumes eviction as
    /// soon as that read completes — including when the open fails, so suspension can't leak.
    private let resumesEvictionAfterFirstRead: Bool

    init(
        url: URL,
        startOffset: UInt64,
        ledger: OwnLineLedger,
        resumesEvictionAfterFirstRead: Bool = false,
        onExternal: @escaping @Sendable ([LogEntry]) -> Void
    ) {
        self.url = url
        self.offset = startOffset
        self.ledger = ledger
        self.resumesEvictionAfterFirstRead = resumesEvictionAfterFirstRead
        self.onExternal = onExternal
    }

    /// Cancels the source so its cancel handler closes the fd; otherwise a resumed source (retained by
    /// libdispatch) would outlive this object and leak the descriptor. Safe here: the event handler
    /// holds a strong `self` for its duration, so no handler is running while this deinit runs. Moot
    /// for the process-lifetime `ActivityLog.shared`, but tidy for throwaway instances (tests).
    deinit {
        source?.cancel()
    }

    /// Opens the file, arms the watch, and reads anything appended between the viewer's load and now.
    func start() {
        queue.async { [self] in
            openAndArm()
            readNew()
            if resumesEvictionAfterFirstRead {
                ledger.resumeEviction()
            }
        }
    }

    /// Re-anchor to the current end of file — used when the viewer clears the log so the tailer does
    /// not re-import the wiped lines. Runs on `queue` to stay ordered with reads.
    func reanchor() {
        queue.async { [self] in
            offset = currentSize()
            partial.removeAll()
        }
    }

    // MARK: queue-confined internals

    private func currentSize() -> UInt64 {
        var status = stat()
        guard fd >= 0, fstat(fd, &status) == 0 else { return 0 }
        return UInt64(status.st_size)
    }

    /// When set, the next successful arm anchors at the (new) file's end instead of keeping the
    /// current offset — the rename branch's intent, remembered here so a RETRIED re-arm still
    /// lands at the new EOF rather than re-reading a whole replacement file from a stale offset.
    private var anchorAtEndOnNextArm = false
    /// Bounded retries for transient `open()` failures (descriptor pressure under load). A silent
    /// give-up left the tailer dead for the rest of the session — live updates just stopped, with
    /// nothing in the UI to say why. ~5s of retries outlives any transient spike.
    private var openRetriesRemaining = 20

    /// (Re)opens the read descriptor and its watch. `O_CREAT` without `O_TRUNC` makes this race-free
    /// against the writer still creating the file — it creates an empty file if missing (the writer's
    /// `O_APPEND` then shares that inode) and never truncates existing content.
    private func openAndArm() {
        // Relinquish the old fd WITHOUT closing it here: a dispatch source's fd must stay valid until
        // its (async) cancel handler runs, and that handler is this fd's sole closer. Closing it now
        // would both violate that contract and free the descriptor number, which `open()` below would
        // deterministically reuse — so the old source's pending cancel handler would then close the
        // NEW source's fd, silently killing the watch on the very reopen (trim/atomic-replace) this
        // path exists to handle. Leaving it open forces `open()` to return a different number.
        source?.cancel()
        source = nil
        fd = -1

        let opened = open(url.path, O_RDONLY | O_CREAT, 0o644)
        guard opened >= 0 else {
            if openRetriesRemaining > 0 {
                openRetriesRemaining -= 1
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                    guard let self, self.fd < 0 else { return }
                    self.openAndArm()
                    // A successful retried arm has already applied any pending EOF anchor; this
                    // read then picks up from the correct offset (the catch-up window on a
                    // first-open retry, or nothing at all after a rename re-arm).
                    self.readNew()
                }
            }
            return
        }
        openRetriesRemaining = 20   // healthy again; future failures get a fresh budget
        fd = opened

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // The inode we held was unlinked/replaced (the trim's atomic rename). Drain what the
                // old inode still holds past our offset FIRST — a coalesced [.write, .rename]
                // delivery otherwise dropped lines written just before the swap — then re-establish
                // on the new file and anchor at its end (the trim seeded it with the old tail, which
                // is already reflected in `entries` or was just drained above). The anchor rides
                // `anchorAtEndOnNextArm` so it applies on the ARMED file even when the re-arm has
                // to retry — setting the offset here from a failed (fd -1) state anchored at 0 and
                // re-imported the entire replacement file as duplicates once a retry succeeded.
                self.readNew()
                self.anchorAtEndOnNextArm = true
                self.openAndArm()
            } else {
                self.readNew()
            }
        }
        source.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        self.source = source
        source.resume()

        if anchorAtEndOnNextArm {
            anchorAtEndOnNextArm = false
            offset = currentSize()
            partial.removeAll()
        }
    }

    private func readNew() {
        guard fd >= 0 else { return }
        let size = currentSize()
        if size < offset {
            // Truncated in place (the viewer cleared the log) — re-anchor to the new, shorter end.
            offset = size
            partial.removeAll()
            return
        }
        guard size > offset else { return }

        let wanted = Int(size - offset)
        var buffer = Data(count: wanted)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return pread(fd, base, wanted, off_t(offset))
        }
        guard read > 0 else { return }
        offset += UInt64(read)

        var chunk = partial
        chunk.append(read == wanted ? buffer : buffer.prefix(read))
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
            partial = chunk           // no complete line yet; hold for the next event
            return
        }
        let complete = chunk[...lastNewline]
        partial = Data(chunk[chunk.index(after: lastNewline)...])

        var external: [LogEntry] = []
        for lineBytes in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let line = String(data: Data(lineBytes), encoding: .utf8) else { continue }
            if ledger.consume(line) { continue }        // our own write — already shown
            if let entry = LogEntry.parse(line) { external.append(entry) }
        }
        guard !external.isEmpty else { return }
        DispatchQueue.main.async { [onExternal] in onExternal(external) }
    }
}

// MARK: - File writer

/// Appends log text to a file on a dedicated serial queue, keeping one `FileHandle` open across
/// writes instead of an open/seek/close per line. All handle access is confined to `queue`. Adapted
/// from SyncCloud's `LogFileWriter`, including its cross-process `flock` trim lock: the main app and
/// the menu-bar Helper both write `~/pdf-utils.log` (the Helper records Finder-triggered runs), so
/// the shared file needs the same trim serialization SyncCloud uses for its app + CLI. Internal so
/// tests can drive the trim/clear behavior directly.
final class LogFileWriter: @unchecked Sendable {
    private static let defaultMaxFileSize = 5 * 1024 * 1024

    private let url: URL
    private let queue = DispatchQueue(label: "com.pdfutils.activitylog", qos: .utility)
    private var handle: FileHandle?
    /// Inode of the file `handle` was opened against. Appends compare it to the path's current inode
    /// so an external replacement (or deletion) of the log is detected and the handle reopened.
    private var handleFileIdentity: UInt64?
    private let maxFileSize: Int

    private var bytesSinceTrimCheck = 0
    private let trimCheckInterval: Int

    init(url: URL, maxFileSize: Int = LogFileWriter.defaultMaxFileSize) {
        self.url = url
        self.maxFileSize = maxFileSize
        trimCheckInterval = min(1024 * 1024, max(1, maxFileSize / 2))
        queue.async { [self] in
            withTrimLock { trimTailIfOversized(maxFileSize: maxFileSize) }
            openHandle()
        }
    }

    /// Runs `body` holding an exclusive `flock` on a sidecar `<log>.lock` file. The main app and the
    /// menu-bar Helper both write `~/pdf-utils.log`, and a trim is a read-tail + atomic-rename of the
    /// whole file: two concurrent trims could each rewrite from a stale tail and clobber the other's
    /// result. The lock serializes trims across processes; each caller re-stats the size INSIDE
    /// `body`, so a trim that lost the race re-checks and finds nothing left to do.
    ///
    /// Appends deliberately stay off this lock — `O_APPEND` already makes each write atomic across
    /// processes, and a cross-process syscall on every line isn't worth it. The one accepted residual
    /// is that the other process's in-flight append can land on the old inode during our rename and
    /// be lost; its next append's inode-identity check (see ``append``) reopens and self-heals. If
    /// the lock file can't be opened, the trim proceeds unguarded rather than letting the log grow
    /// unbounded. Runs on `queue`.
    private func withTrimLock(_ body: () -> Void) {
        let fd = open(url.path + ".lock", O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { body(); return }
        defer { close(fd) }  // closing the descriptor releases the flock too
        _ = flock(fd, LOCK_EX)
        body()
        _ = flock(fd, LOCK_UN)
    }

    /// Inode of the item currently at `url`; nil when the path does not exist. Runs on `queue`.
    private func currentFileIdentity() -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// (Re)opens the write handle positioned at end-of-file, creating the file if missing, and
    /// records the opened file's identity. Runs on `queue`.
    private func openHandle() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        handleFileIdentity = handle == nil ? nil : currentFileIdentity()
    }

    /// Tail-trims the file when it exceeds `maxFileSize`, keeping the newest half of the cap aligned
    /// to a line boundary, so the log can't grow unbounded across runs. Runs on `queue`.
    private func trimTailIfOversized(maxFileSize: Int) {
        guard maxFileSize > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxFileSize,
              let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }

        let keepBytes = maxFileSize / 2
        guard (try? readHandle.seek(toOffset: UInt64(size - keepBytes))) != nil,
              var tail = try? readHandle.readToEnd() else { return }
        // Drop the partial first line so the trimmed file still starts at a line boundary.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        try? tail.write(to: url, options: .atomic)
    }

    /// `completion` runs on the writer queue only after the bytes actually land, so callers can
    /// sequence their own bookkeeping against the disk state (see `ActivityLog.log`). On a failed
    /// write the completion is skipped — the entry then exists in neither destination, which keeps
    /// the viewer from showing a line the file does not hold.
    func append(_ text: String, then completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let data = text.data(using: .utf8) else { return }
            // Reopen if the path's current inode no longer matches the handle's — never opened,
            // removed, or replaced externally — so a stale handle can't write into an orphaned inode.
            if self.handle == nil || self.currentFileIdentity() != self.handleFileIdentity {
                try? self.handle?.close()
                self.handle = nil
                self.openHandle()
            }
            var landed = false
            if let handle = self.handle {
                if (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: data)) != nil {
                    landed = true
                }
            } else {
                // Last-resort fallback when the handle could not be opened. Append manually — a bare
                // `.atomic` write would replace the whole log with this one line. Self-heals next append.
                let existing = (try? Data(contentsOf: self.url)) ?? Data()
                landed = (try? (existing + data).write(to: self.url, options: .atomic)) != nil
            }
            self.bytesSinceTrimCheck += data.count
            if self.bytesSinceTrimCheck >= self.trimCheckInterval {
                self.bytesSinceTrimCheck = 0
                self.trimMidSessionIfOversized()
            }
            if landed {
                completion?()
            }
        }
    }

    /// Mid-session counterpart to the init-time trim. The trim rewrites the file atomically (new
    /// inode), so the open handle is closed first and reopened after. Runs on `queue`.
    private func trimMidSessionIfOversized() {
        // The size check runs UNDER the trim lock: the other process may have just trimmed, and a
        // decision made from a pre-lock stat would re-cut a file already back under the cap.
        withTrimLock {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > maxFileSize else { return }
            try? handle?.close()
            handle = nil
            trimTailIfOversized(maxFileSize: maxFileSize)
            openHandle()
        }
    }

    /// Blocks until every append/clear enqueued before this call has finished — the barrier behind
    /// `ActivityLog.flushToDisk()`.
    func flush() {
        queue.sync {}
    }

    /// Truncates the file to empty, keeping the open handle valid. `completion` runs on the writer
    /// queue right after the truncate, ordered after every previously enqueued append.
    func clear(then completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            defer { completion?() }
            guard let self else { return }
            if let handle = self.handle {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            } else {
                try? "".write(to: self.url, atomically: true, encoding: .utf8)
            }
        }
    }
}
