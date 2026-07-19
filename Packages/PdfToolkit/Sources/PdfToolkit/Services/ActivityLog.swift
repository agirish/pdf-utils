import Foundation
import SwiftUI

// MARK: - Log level

/// The severity of an Activity Log entry. Ported from SyncCloud's `Events/Logger` so the two apps'
/// logs read and parse identically; pdf-utils is a single process (no CLI sharing the file), so the
/// cross-process machinery SyncCloud carries is deliberately left out here.
public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    /// Informational telemetry — the standard "operation succeeded" event.
    case info = "INFO"
    /// Detailed diagnostics for development.
    case debug = "DEBUG"
    /// A non-critical problem that did not halt the operation.
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

    /// The persisted minimum level, defaulting to `.debug` (log everything) when unset/unrecognized.
    public static func persistedMinimumLevel(from defaults: UserDefaults = .standard) -> LogLevel {
        defaults.string(forKey: minimumLevelDefaultsKey).flatMap(LogLevel.init(rawValue:)) ?? .debug
    }

    /// Entries below this severity are dropped before memory or disk. Lock-guarded because the
    /// logging methods run on the caller's thread.
    public nonisolated var minimumLevel: LogLevel {
        get { minimumLevelBox.value }
        set { minimumLevelBox.value = newValue }
    }
    private let minimumLevelBox = LockedValue<LogLevel>(.debug)

    private static let maxInMemory = 1000

    let writer: LogFileWriter
    /// Ordered handoff from nonisolated loggers to the main actor. `DispatchQueue.main.async`
    /// preserves submission order, so entries land in call order.
    private let pending = LockedValue<[LogEntry]>([])

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.writer = LogFileWriter(url: fileURL)
        self.entries = Self.loadRecent(from: fileURL, limit: Self.maxInMemory)
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

    private func drainPending() {
        let batch = pending.take()
        guard !batch.isEmpty else { return }
        entries.append(contentsOf: batch)
        if entries.count > Self.maxInMemory {
            entries.removeFirst(entries.count - Self.maxInMemory)
        }
    }

    // MARK: Clearing / flushing

    /// Empties the in-memory mirror and the on-disk file. The handoff buffer is dropped twice: once
    /// here (anything already handed off but not yet drained) and once on the writer queue after
    /// the truncate lands (anything a concurrent `log()` appended to disk ahead of the truncate),
    /// so an entry the clear wiped from disk can never resurrect in the viewer.
    public func clearLogs() {
        _ = pending.take()
        entries.removeAll()
        writer.clear { [pending] in
            _ = pending.take()
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
    /// shows the tail of the previous run without waiting for new activity.
    private static func loadRecent(from url: URL, limit: Int) -> [LogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let parsed = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { LogEntry.parse(String($0)) }
        return parsed.count > limit ? Array(parsed.suffix(limit)) : parsed
    }
}

// MARK: - Locked value

/// A minimal lock-guarded cell readable/writable from any thread. Used for the level gate and the
/// nonisolated → main-actor handoff buffer, both touched off the main actor by `log()`.
private final class LockedValue<Value>: @unchecked Sendable {
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

// MARK: - File writer

/// Appends log text to a file on a dedicated serial queue, keeping one `FileHandle` open across
/// writes instead of an open/seek/close per line. All handle access is confined to `queue`. Adapted
/// from SyncCloud's `LogFileWriter` minus the cross-process `flock` trim lock (pdf-utils is a single
/// process — no CLI shares the file). Internal so tests can drive the trim/clear behavior directly.
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
            trimTailIfOversized(maxFileSize: maxFileSize)
            openHandle()
        }
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxFileSize else { return }
        try? handle?.close()
        handle = nil
        trimTailIfOversized(maxFileSize: maxFileSize)
        openHandle()
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
