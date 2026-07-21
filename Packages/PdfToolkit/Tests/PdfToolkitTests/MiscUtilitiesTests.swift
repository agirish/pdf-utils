import Testing
import AppKit
import Foundation
@testable import PdfToolkit

/// Smaller utilities that back the app's plumbing: the user-cancel classifier, the brand name, the
/// operation tracker, the log-level contract, and the log's defaults/history helpers — including the
/// history-exclusion fix that stops previous-session lines appearing twice in the viewer.
@Suite struct MiscUtilitiesTests {

    // MARK: Error.isUserCancelled

    @Test func userCancelledMatchesOnlyTheCocoaCancelError() {
        let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        #expect(cancelled.isUserCancelled)
        // A different code in the same domain is a real error, not a cancel.
        #expect(!NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError).isUserCancelled)
        // A different domain with the same numeric code is unrelated.
        #expect(!NSError(domain: "SomeOtherDomain", code: NSUserCancelledError).isUserCancelled)
        #expect(!PDFOperationError.noInputFiles.isUserCancelled)
    }

    // MARK: AppBrand

    @Test func appBrandDisplayNameIsNeverEmpty() {
        // Whatever the bundle provides (or the "PDF Utils" fallback), the app always has a name to
        // show in the title bar and alerts.
        #expect(!AppBrand.displayName.isEmpty)
    }

    // MARK: AppStateManager

    @MainActor
    @Test func operationTrackerReflectsActiveOperations() {
        let manager = AppStateManager.shared
        let a = "Op-\(UUID().uuidString)", b = "Op-\(UUID().uuidString)"
        defer { manager.endOperation(a); manager.endOperation(b) }

        // The two views of "anything running?" must agree exactly (the old form of this line,
        // `!a || !b` with b == a, was vacuously true no matter what the manager did).
        #expect(manager.hasPendingOperations == !manager.activeOperations.isEmpty)
        manager.beginOperation(b)
        manager.beginOperation(a)
        #expect(manager.hasPendingOperations)
        #expect(manager.activeOperations.keys.contains(a))
        #expect(manager.activeOperations.keys.contains(b))
        // Description is sorted, so it's stable regardless of insertion order.
        let description = manager.pendingOperationsDescription
        #expect(description.contains(a))
        #expect(description.range(of: [a, b].sorted().first!) != nil)

        manager.endOperation(a)
        #expect(!manager.activeOperations.keys.contains(a))
    }

    @MainActor
    @Test func operationTrackerCountsSameNamedConcurrentRuns() {
        // Two windows can run the same tool at once. A Set collapsed them: the first to finish
        // cleared the shared entry and ⌘Q's warning went silent while the twin was still writing.
        let manager = AppStateManager.shared
        let name = "Op-\(UUID().uuidString)"

        manager.beginOperation(name)
        manager.beginOperation(name)
        #expect(manager.pendingOperationsDescription.contains("\(name) (×2)")) // alert shows the stake
        manager.endOperation(name)
        #expect(manager.activeOperations.keys.contains(name)) // the second run is still going
        #expect(!manager.pendingOperationsDescription.contains("×"))           // back to a bare name

        manager.endOperation(name)
        #expect(!manager.activeOperations.keys.contains(name))

        manager.endOperation(name) // unbalanced end is a no-op, not a crash or negative count
        #expect(!manager.activeOperations.keys.contains(name))
    }

    // MARK: LogLevel contract

    @Test func logLevelSeverityIsStrictlyOrdered() {
        #expect(LogLevel.debug.severity < LogLevel.info.severity)
        #expect(LogLevel.info.severity < LogLevel.warning.severity)
        #expect(LogLevel.warning.severity < LogLevel.error.severity)
    }

    @Test func logLevelRawValuesAreThePersistedTokens() {
        // These strings are written to and parsed from the on-disk log — renaming one breaks
        // round-tripping of every existing log line.
        #expect(LogLevel.info.rawValue == "INFO")
        #expect(LogLevel.debug.rawValue == "DEBUG")
        #expect(LogLevel.warning.rawValue == "WARN")
        #expect(LogLevel.error.rawValue == "ERROR")
    }

    @Test func everyLogLevelIconResolves() {
        for level in LogLevel.allCases {
            #expect(!level.icon.isEmpty)
            #expect(NSImage(systemSymbolName: level.icon, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(level.icon) for \(level)")
        }
    }

    // MARK: ActivityLog defaults / file location

    @MainActor
    @Test func persistedMinimumLevelReadsTheKeyAndDefaultsToInfo() {
        let name = "pdfutils.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(ActivityLog.defaultMinimumLevel == .info)
        #expect(ActivityLog.persistedMinimumLevel(from: defaults) == .info)      // unset → info
        defaults.set("WARN", forKey: ActivityLog.minimumLevelDefaultsKey)
        #expect(ActivityLog.persistedMinimumLevel(from: defaults) == .warning)
        defaults.set("nonsense", forKey: ActivityLog.minimumLevelDefaultsKey)
        #expect(ActivityLog.persistedMinimumLevel(from: defaults) == .info)      // unknown → info
        #expect(ActivityLog.minimumLevelDefaultsKey == "pdfutils.logMinimumLevel")
    }

    @MainActor
    @Test func defaultFileURLIsIsolatedToTempUnderTests() {
        // The test-runner detection must divert the log to a temp file so a test run never writes to
        // the real ~/pdf-utils.log.
        let url = ActivityLog.defaultFileURL()
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(url.pathExtension == "log")
    }

    // MARK: recordSaved rendering

    @MainActor
    @Test func recordSavedWithoutDetailUsesTheSavedArrow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("misc-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActivityLog(fileURL: url)

        log.recordSaved("Rotate", to: URL(fileURLWithPath: "/tmp/rotated.pdf"), bytes: nil, detail: nil)
        log.flushToDisk()

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(contents.contains("Rotate: saved →"))
        #expect(contents.contains("rotated.pdf"))
    }

    // MARK: History loading from disk

    @Test func loadOlderThanReadsPreviousSessionLinesNewestFirst() throws {
        // The on-disk read path behind "Earlier sessions": only entries older than the session
        // boundary come back, newest first, so a relaunch can show prior-run lines without pulling
        // in the current session's own entries.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let old1 = LogEntry(timestamp: Date(timeIntervalSinceNow: -3600), level: .info, message: "OLD ONE")
        let old2 = LogEntry(timestamp: Date(timeIntervalSinceNow: -1800), level: .info, message: "OLD TWO")
        let current = LogEntry(timestamp: Date(timeIntervalSinceNow: 100), level: .info, message: "CURRENT")
        let text = [old1, old2, current].map(\.formattedString).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        // Newest-first, with the not-yet-past "CURRENT" line excluded by the boundary.
        #expect(ActivityLogHistory.loadOlderThan(Date(), fileURL: url).map(\.message) == ["OLD TWO", "OLD ONE"])
    }
}
