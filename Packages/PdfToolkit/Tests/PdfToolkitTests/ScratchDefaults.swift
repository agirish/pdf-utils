import Foundation

// Scratch `UserDefaults` suites, and the cleanup that actually reclaims them.
//
// Emptying a suite is not the same as deleting it. `removePersistentDomain(forName:)` — the
// obvious-looking teardown — clears the keys but leaves `~/Library/Preferences/<suite>.plist`
// on disk as an empty 42-byte property list. Measured on Swift 6.3.3 / Xcode 26.6: neither
// `removePersistentDomain(forName:)`, nor `removeSuite(named:)`, nor `CFPreferencesAppSynchronize`,
// nor any combination of the three removes the file. Unlinking it is the only thing that does.
//
// Unlinking during the run is still not sufficient, because `cfprefsd` is a separate daemon that
// holds the suite in memory and writes it back out *after* the test process exits. Measured here,
// it resurrects essentially every suite a run unlinks — so eager cleanup alone can never reach a
// steady state on its own.
//
// What bounds the directory is the ledger: each run records the suites it wiped, and later runs
// delete what earlier runs recorded. By then the owning process is gone, `cfprefsd` has no live
// handle, and the unlink sticks (verified: files stay gone). The steady state is therefore a
// constant *non-zero* count — roughly one run's worth of suites — not zero. That is intended.
//
// A ledger is re-swept by every subsequent run for an hour rather than discarded on first pass,
// because the write-back is lazy: a single sweep reclaims only what the daemon has flushed by that
// moment, and anything it writes afterwards is orphaned for good once the record is gone.
//
// Every cleanup path must funnel through `wipeDefaultsSuite(_:)`, because that is where ledger
// entries are recorded. Recording from a scratch type's initializer instead would miss every plain
// `defer { wipeDefaultsSuite(suite) }` site, and those are most of them.

/// Removes a scratch defaults suite and the plist backing it, and records it for the next run's
/// sweep. Safe to call more than once for the same suite.
///
/// Only suites created by this test target are eligible; see `isScratchSuiteName`. Anything else —
/// the real `com.abhishekgirish.PdfUtils` app domain above all — is ignored rather than deleted.
func wipeDefaultsSuite(_ name: String) {
    guard isScratchSuiteName(name) else {
        assertionFailure("refusing to wipe non-scratch defaults suite \(name)")
        return
    }

    scratchSuiteLedger.sweepPreviousRunsOnce()

    let defaults = UserDefaults.standard
    defaults.removePersistentDomain(forName: name)
    defaults.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    try? FileManager.default.removeItem(at: scratchSuitePlistURL(name))

    // Recorded last, and unconditionally: the unlink above usually loses to cfprefsd's post-exit
    // write-back, so the ledger entry is what actually reclaims this suite — one run later.
    scratchSuiteLedger.record(name)
}

/// A `UserDefaults` suite that wipes itself when the last reference goes away, for factories that
/// hand back a suite with nowhere to hang a `defer`. Mirrors `FixtureDir`'s deinit-based cleanup.
final class ScratchDefaults: UserDefaults {
    let suiteName: String

    init(suiteName: String = scratchSuiteName()) {
        self.suiteName = suiteName
        super.init(suiteName: suiteName)!
        // Start from a clean domain: a recycled name would otherwise inherit stale keys.
        removePersistentDomain(forName: suiteName)
    }

    deinit { wipeDefaultsSuite(suiteName) }
}

/// A fresh, collision-free scratch suite name carrying this target's reserved prefix.
func scratchSuiteName() -> String { "pdfutils.tests.\(UUID().uuidString)" }

// MARK: - Suite naming and paths

/// The prefixes this target is allowed to delete. An allowlist, not a denylist: a cleanup path that
/// can only ever name a scratch suite cannot be talked into deleting a real preferences domain.
private let scratchSuitePrefixes = ["pdfutils.tests.", "PDFExportCoordinatorTests-"]

func isScratchSuiteName(_ name: String) -> Bool {
    // A separator would let a crafted name escape ~/Library/Preferences entirely.
    guard !name.contains("/"), !name.contains("..") else { return false }
    return scratchSuitePrefixes.contains { name.hasPrefix($0) }
}

private func scratchSuitePlistURL(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences")
        .appendingPathComponent("\(name).plist")
}

// MARK: - Cross-run ledger

/// Records the scratch suites this run wiped, and on first use deletes the ones recorded by runs
/// that have since exited.
///
/// One ledger file per run rather than one shared file. This Mac runs concurrent test processes — a
/// self-hosted CI runner alongside local sessions, and other repos' suites — and a single shared
/// file would let one run truncate another's un-swept entries, stranding a run's worth of plists for
/// good. Per-run files mean a run only ever reads ledgers it can prove are finished.
private let scratchSuiteLedger = ScratchSuiteLedger()

private final class ScratchSuiteLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var didSweep = false
    private var handle: FileHandle?

    /// How long a finished run's ledger is kept and re-swept after its last write.
    ///
    /// Measured, not guessed: `cfprefsd` writes a suite back lazily, and a sweep that deletes the
    /// ledger on first pass reclaims only the entries flushed so far. In a four-run measurement
    /// that stranded 14 of one run's 24 suites permanently — the daemon wrote them out *after* the
    /// sweep had already discarded the record of them. Keeping the ledger and re-sweeping it on
    /// every later run closes that window; an hour is far past any observed write-back lag.
    private let retention: TimeInterval = 60 * 60

    /// Repo-specific on purpose. SyncCloud keeps `SyncCloudTestScratchSuites.ledger` beside this;
    /// sharing one path would have each project's sweep discard the other's pending entries.
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/PdfUtilsTestScratchSuites", isDirectory: true)

    /// `<pid>-<uuid>.ledger`. The pid identifies the owning run so a later run can tell whether it
    /// has exited; the uuid keeps a retained ledger from being appended to by a recycled pid.
    private let ownLedgerName =
        "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).ledger"

    private var ownLedgerURL: URL { directory.appendingPathComponent(ownLedgerName) }

    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = "\(name)\n".data(using: .utf8) else { return }
        if handle == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: ownLedgerURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: ownLedgerURL)
        }
        try? handle?.seekToEnd()
        try? handle?.write(contentsOf: data)
        try? handle?.synchronize()
    }

    /// Deletes the suites recorded by every finished run. Runs once per process.
    func sweepPreviousRunsOnce() {
        // The lock is held for the whole sweep, not just the `didSweep` check, so a concurrent
        // `record` can't interleave with the directory scan.
        lock.lock()
        defer { lock.unlock() }
        guard !didSweep else { return }
        didSweep = true

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        for ledger in entries
        where ledger.pathExtension == "ledger" && ledger.lastPathComponent != ownLedgerName {
            guard let idle = idleTime(of: ledger), hasExited(ledger) else { continue }
            if let contents = try? String(contentsOf: ledger, encoding: .utf8) {
                for suite in contents.split(separator: "\n").map(String.init)
                where isScratchSuiteName(suite) {
                    try? fm.removeItem(at: scratchSuitePlistURL(suite))
                }
            }
            // Kept until well past any pending write-back, so late arrivals are caught by a later
            // run's sweep rather than orphaned. Discarding it here is what leaked before.
            if idle > retention { try? fm.removeItem(at: ledger) }
        }
    }

    /// Whether the run that wrote `ledger` has exited — so unlinking its suites will stick.
    private func hasExited(_ ledger: URL) -> Bool {
        let name = ledger.deletingPathExtension().lastPathComponent
        guard let pid = Int32(name.prefix(while: { $0 != "-" })) else { return true }
        // A recycled pid would otherwise keep a finished run's ledger alive forever; age it out.
        if let idle = idleTime(of: ledger), idle > retention { return true }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private func idleTime(of ledger: URL) -> TimeInterval? {
        guard let modified = (try? ledger.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        return Date().timeIntervalSince(modified)
    }
}
