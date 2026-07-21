import Cocoa
import PDFKit
import ServiceManagement
import UserNotifications
import PdfToolkit

/// The resident menu-bar agent behind the Finder Sync integration.
///
/// The Finder extension is sandboxed and can't touch the user's files, so it writes a small
/// `command.json` into its container and pings us via the `pdfutils-helper://` URL scheme. We run
/// unsandboxed (full file access) and always resident, so the work starts immediately — no
/// cold-launching the full GUI app — and we can post progress notifications.
@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    private static let helperBundleID = "com.pdfutils.PdfUtils.Helper"
    private static let mainAppBundleID = "com.pdfutils.PdfUtils"

    /// The extension drops its requests here (its own sandbox container, which we can read) — one
    /// `command-<millis>-<uuid>.json` per request. The bare `command.json` name is the pre-queue
    /// format, still drained so an older extension instance Finder hasn't reloaded keeps working.
    private let commandDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.pdfutils.PdfUtils.FinderSync/Data")

    /// Interactive requests (unlock, extract) prompt through modal alerts. Spawning each as its
    /// own Task stacked prompts: `runModal`'s nested run loop drains the main queue, so a second
    /// request's alert opened ON TOP of the first and the stack had to be answered newest-first —
    /// completion order inverted request order. This FIFO runs them one at a time in the order
    /// they were made; non-interactive work still dispatches to the work queue immediately.
    private var interactiveJobs: [() async -> Void] = []
    private var interactiveRunnerActive = false

    /// Work-queue batches dispatched but not yet finished (compress/merge/rotate/extract writes).
    /// Together with the interactive FIFO state this is "work the user asked for that hasn't
    /// happened yet" — the request files are already consumed, so quitting abandons it silently
    /// and the staleness cutoff stops any replay. `applicationShouldTerminate` warns first.
    private var activeBatches = 0

    private func enqueueInteractive(_ job: @escaping () async -> Void) {
        interactiveJobs.append(job)
        guard !interactiveRunnerActive else { return }
        interactiveRunnerActive = true
        Task { @MainActor [self] in
            while !interactiveJobs.isEmpty {
                let next = interactiveJobs.removeFirst()
                await next()
            }
            interactiveRunnerActive = false
        }
    }

    /// Serial so Finder-triggered PDF work never runs PDFKit on two threads at once — the same
    /// invariant the in-app tools honor via `PDFBackgroundWork`.
    private let workQueue = DispatchQueue(label: "org.pdfutils.helper.work", qos: .userInitiated)

    private var statusItem: NSStatusItem?
    private var flashReset: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Receive pdfutils-helper:// URLs (the extension's ping) whether we're cold-launched or
        // already running.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        setUpStatusItem()
        let center = UNUserNotificationCenter.current()
        center.delegate = self // so banners show even while the helper is the active app
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Finder-triggered work records into the same `~/pdf-utils.log` the app writes, so honor the
        // "Activity logging level" the user picked in the app. That setting lives in the app's
        // defaults domain, not the helper's own (we have a separate bundle id), so read it explicitly;
        // an unreadable/absent value falls back to the shared default level. Touching `.shared` here
        // also initializes it on the main actor, ahead of the background work queue's log calls.
        if let appDefaults = UserDefaults(suiteName: Self.mainAppBundleID) {
            ActivityLog.shared.minimumLevel = ActivityLog.persistedMinimumLevel(from: appDefaults)
        }

        // A ping may have launched us specifically to handle a request already on disk.
        processCommand()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeMenuBarIcon()
        item.menu = buildMenu()
        statusItem = item
    }

    /// A "PDF" wordmark in a rounded tile — echoes the app icon (a rounded purple tile with a bold
    /// PDF), but drawn as a monochrome template so it sits correctly in the menu bar and adapts to
    /// light/dark automatically. A scaled full-color app icon would render "PDF" only a couple of
    /// pixels tall, so the wordmark is drawn directly instead.
    private static func makeMenuBarIcon() -> NSImage {
        let font = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
        let text = "PDF" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .kern: 0.4]
        let textSize = text.size(withAttributes: attrs)
        let padX: CGFloat = 4
        let size = NSSize(width: ceil(textSize.width) + padX * 2, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let border = NSBezierPath(
            roundedRect: NSRect(x: 0.9, y: 0.9, width: size.width - 1.8, height: size.height - 1.8),
            xRadius: 3.6, yRadius: 3.6)
        border.lineWidth = 1.3
        NSColor.black.setStroke()
        border.stroke()
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2 - 0.3),
                  withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "PDF Utils"
        return image
    }

    /// Permission-free feedback: briefly swap the menu-bar icon to a status glyph, then restore the
    /// PDF wordmark. Reliable where notifications aren't (an ad-hoc-signed helper doesn't get a
    /// persistent notification registration).
    private func flashStatusIcon(success: Bool) {
        guard let button = statusItem?.button else { return }
        let glyph = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            accessibilityDescription: success ? "Done" : "Failed")
        glyph?.isTemplate = true
        button.image = glyph
        flashReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.statusItem?.button?.image = Self.makeMenuBarIcon() }
        flashReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: reset)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    /// Rebuilt on every open (see `menuNeedsUpdate`): the "Start at Login" state reflects
    /// `SMAppService` status the user can flip in System Settings ▸ Login Items at any time, so a
    /// build-once menu showed a stale checkmark until the next in-menu toggle or relaunch.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "PDF Utils", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(title: "Open PDF Utils", action: #selector(openMainApp)))
        let login = item(title: "Start at Login", action: #selector(toggleLoginItem))
        login.state = (loginAgent.status == .enabled) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit PDF Utils Helper", action: #selector(quit)))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openMainApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mainAppBundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private var pendingWorkCount: Int {
        activeBatches + interactiveJobs.count + (interactiveRunnerActive ? 1 : 0)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Loop, don't snapshot once: the alert's own nested run loop keeps delivering pings, so
        // requests can be consumed WHILE it is up — work the user's "Quit Anyway" never covered.
        // Re-check after each answer and only quit when nothing new appeared; the loop only
        // repeats when new requests arrived mid-alert, so it terminates with the user's intent
        // honestly informed.
        var warnedAbout = pendingWorkCount
        while warnedAbout > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "PDF work is still in progress"
            alert.informativeText = "Quitting now abandons the queued Finder requests — they won't re-run on the next launch — and can leave a half-written output from the file being processed."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Keep Working")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            let current = pendingWorkCount
            if current <= warnedAbout { break }   // nothing new since the warning — honor the quit
            warnedAbout = current                 // more arrived mid-alert: warn again, fresh count
        }
        return .terminateNow
    }

    // MARK: - Login item

    /// Launch-at-login is done through a bundled LaunchAgent the helper registers for itself
    /// (`SMAppService.loginItem` can't self-register — it looks inside the *calling* app's bundle
    /// and returns notFound).
    private var loginAgent: SMAppService { SMAppService.agent(plistName: "\(Self.helperBundleID).plist") }

    @objc private func toggleLoginItem() {
        let service = loginAgent
        let turningOn = service.status != .enabled
        do {
            if turningOn { try service.register() } else { try service.unregister() }
        } catch {
            showInfo(title: "Couldn't change “Start at Login”", text: error.localizedDescription)
            return
        }
        // No menu rebuild needed here: `menuNeedsUpdate` re-reads the state on every open.
        // SMAppService can register but leave the item awaiting the user's approval in Login Items.
        if turningOn, loginAgent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            showInfo(title: "Approve “PDF Utils Helper”",
                     text: "Login Items just opened — turn on “PDF Utils Helper” under “Allow in the Background” to finish enabling launch at login.")
        } else if turningOn {
            showInfo(title: "PDF Utils Helper", text: "It’ll now start automatically at login.")
        }
    }

    private func showInfo(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - URL ping

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        // Every pdfutils-helper:// URL means the same thing right now: "a request is waiting."
        processCommand()
    }

    // MARK: - Command processing

    private func processCommand() {
        // Refresh the level gate on every drain: the helper is resident for weeks, and the user
        // can change Settings ▸ Activity logging level in the app at any time — a launch-time-only
        // read left this process logging at a long-stale level.
        if let appDefaults = UserDefaults(suiteName: Self.mainAppBundleID) {
            ActivityLog.shared.minimumLevel = ActivityLog.persistedMinimumLevel(from: appDefaults)
        }
        for url in pendingCommandURLs() {
            processOneCommand(at: url)
        }
    }

    /// Every queued request, oldest first — ordering rules live in ``FinderCommandFiles`` (shared
    /// with the extension, unit-tested in the package).
    private func pendingCommandURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: commandDirectory.path)) ?? []
        return FinderCommandFiles.pendingOrder(among: names).map { commandDirectory.appendingPathComponent($0) }
    }

    private func processOneCommand(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url) // consume so we never reprocess
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String,
              let paths = obj["paths"] as? [String], !paths.isEmpty else {
            // A request the user made but we can't honor must not vanish without a trace.
            ActivityLog.shared.warning("Finder request dropped: could not parse \(url.lastPathComponent)")
            flashStatusIcon(success: false)
            return
        }
        // Missing/garbled `ts` counts as stale — both extension formats always write it, so its
        // absence means a file nobody just created. Same no-trace principle as the parse drop:
        // warn AND flash, so a swallowed right-click is at least visibly a failure.
        if FinderCommandFiles.isStale(ts: obj["ts"]) {
            let age = (obj["ts"] as? TimeInterval).map { Int(Date().timeIntervalSince1970 - $0) }
            ActivityLog.shared.warning(
                "Finder request dropped: \(action) request was \(age.map { "\($0)s old" } ?? "missing its timestamp") — likely orphaned by a helper exit, not re-run")
            flashStatusIcon(success: false)
            return
        }
        let inputs = paths.map { URL(fileURLWithPath: $0) }
        // Captured on the main actor so the background work queue can record into the shared log
        // without touching the main-actor-isolated `.shared` accessor off-thread (the logging methods
        // themselves are nonisolated). Attribution matches the in-app tools so the log reads uniformly
        // regardless of whether an operation started in the app or from a Finder right-click.
        let log = ActivityLog.shared

        switch action {
        case "compress":
            notify(id: "pdfutils.compress", title: "Compress PDF", body: startBody(inputs.count))
            activeBatches += 1
            workQueue.async { [self] in
                var revealed: [URL] = []
                var failed: [String] = []
                var firstFailure: String?
                for input in inputs {
                    let output = Self.uniqueOutput(for: input, suffix: "compressed")
                    do {
                        try PDFToolkit.compress(inputURL: input, outputURL: output, quality: 0.6)
                        revealed.append(output)
                        log.recordSaved(Tool.compress.title, to: output, bytes: Self.fileSize(of: output))
                    } catch {
                        failed.append(input.lastPathComponent)
                        if firstFailure == nil { firstFailure = error.localizedDescription }
                        log.error("\(Tool.compress.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                finish(id: "pdfutils.compress", title: "Compress PDF", revealed: revealed, failed: failed, failureDetail: firstFailure)
            }

        case "merge":
            notify(id: "pdfutils.merge", title: "Merge PDFs", body: startBody(inputs.count))
            activeBatches += 1
            workQueue.async { [self] in
                // Combined in Finder's selection order, into the first file's folder.
                let output = Self.uniqueOutput(inDirectory: inputs[0].deletingLastPathComponent(), name: "Merged")
                do {
                    try PDFToolkit.merge(inputURLs: inputs, outputURL: output)
                    log.recordSaved(Tool.merge.title, to: output, bytes: Self.fileSize(of: output), detail: "\(inputs.count) files")
                    finish(id: "pdfutils.merge", title: "Merge PDFs", revealed: [output], failed: [])
                } catch {
                    log.error("\(Tool.merge.title) failed: \(error.localizedDescription)")
                    finish(id: "pdfutils.merge", title: "Merge PDFs", revealed: [], failed: ["merge"],
                           failureDetail: error.localizedDescription)
                }
            }

        case "rotate":
            let turns = obj["quarterTurns"] as? Int ?? 1
            notify(id: "pdfutils.rotate", title: "Rotate PDF", body: startBody(inputs.count))
            activeBatches += 1
            workQueue.async { [self] in
                var revealed: [URL] = []
                var failed: [String] = []
                var firstFailure: String?
                for input in inputs {
                    let count = PDFToolkit.pageCount(at: input) ?? 0
                    let output = Self.uniqueOutput(for: input, suffix: "rotated")
                    do {
                        try PDFToolkit.rotate(inputURL: input, outputURL: output, pageIndices: Array(0..<count), quarterTurns: turns)
                        revealed.append(output)
                        log.recordSaved(Tool.rotate.title, to: output, bytes: Self.fileSize(of: output))
                    } catch {
                        failed.append(input.lastPathComponent)
                        if firstFailure == nil { firstFailure = error.localizedDescription }
                        log.error("\(Tool.rotate.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                finish(id: "pdfutils.rotate", title: "Rotate PDF", revealed: revealed, failed: failed, failureDetail: firstFailure)
            }

        case "extract":
            if let input = inputs.first {
                // Immediate feedback at drain time: the page-count probe rides the work queue, so
                // behind a long batch the prompt can be minutes away — silence until a modal
                // steals focus read as a swallowed click.
                notify(id: "pdfutils.extract", title: "Extract Pages", body: "Getting ready…")
                enqueueInteractive { await self.runExtract(input, log: log) }
            }

        case "unlock":
            enqueueInteractive { await self.runUnlock(inputs) }

        default:
            break
        }
    }

    /// Hops back to the main actor to reveal results in Finder and post the completion notice.
    /// `failureDetail` is the first real error's message; when nothing succeeded it replaces the
    /// old guessing body ("may be open elsewhere or damaged"), which actively misled for the most
    /// common failure — a password-protected input whose precise, actionable message otherwise
    /// reached only the Activity Log.
    private nonisolated func finish(
        id: String,
        title: String,
        revealed: [URL],
        failed: [String],
        failureDetail: String? = nil
    ) {
        Task { @MainActor in
            if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
            flashStatusIcon(success: failed.isEmpty)
            activeBatches = max(0, activeBatches - 1)
            let body: String
            if failed.isEmpty {
                body = revealed.count <= 1 ? "Done — revealed in Finder." : "Done — \(revealed.count) files revealed in Finder."
            } else if revealed.isEmpty {
                body = failureDetail ?? "Couldn't complete. The file may be open elsewhere or damaged."
                // The notification below rides a channel that does not deliver for this nested
                // helper (see flashStatusIcon's rationale and the Finder-integration notes) — so
                // when the user's click produced NOTHING, say why in a channel that works.
                // Through the FIFO, not directly: a direct runModal here stacked this alert on
                // top of an open unlock/extract prompt (where a Return aimed at the prompt
                // dismissed the failure unread) and on other failure alerts — the exact LIFO
                // shape the FIFO exists to prevent. Partial results skip the modal: the Finder
                // reveal + flash already show something happened, and the log has the detail.
                let alertBody = body
                enqueueInteractive { self.showInfo(title: title, text: alertBody) }
            } else {
                body = "\(revealed.count) done, \(failed.count) failed."
            }
            notify(id: id, title: title, body: body)
        }
    }

    // MARK: - Remove password (interactive: needs a prompt, so it runs on the main actor)

    private enum UnlockOutcome { case success(URL), notEncrypted, failed(String), cancelled }

    private func runUnlock(_ inputs: [URL]) async {
        var revealed: [URL] = []
        var notProtected: [String] = []
        var failed: [String] = []
        loop: for input in inputs {
            switch await unlockOne(input) {
            case .success(let output):
                revealed.append(output)
                ActivityLog.shared.recordSaved(Tool.protect.title, to: output, bytes: Self.fileSize(of: output))
            case .notEncrypted: notProtected.append(input.lastPathComponent)
            case .failed(let reason):
                failed.append(input.lastPathComponent)
                ActivityLog.shared.error("\(Tool.protect.title) failed for \(input.lastPathComponent): \(reason)")
            case .cancelled: break loop // user backed out — stop prompting for the rest
            }
        }
        if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
        // Pure cancel (nothing attempted) stays silent.
        guard !(revealed.isEmpty && notProtected.isEmpty && failed.isEmpty) else { return }
        flashStatusIcon(success: failed.isEmpty)

        let body: String
        if !revealed.isEmpty && notProtected.isEmpty && failed.isEmpty {
            body = revealed.count == 1 ? "Unlocked — revealed in Finder." : "Unlocked \(revealed.count) files — revealed in Finder."
        } else if revealed.isEmpty && failed.isEmpty {
            body = notProtected.count == 1 ? "“\(notProtected[0])” isn't password-protected." : "\(notProtected.count) files weren't password-protected."
        } else {
            var parts: [String] = []
            if !revealed.isEmpty { parts.append("\(revealed.count) unlocked") }
            if !notProtected.isEmpty { parts.append("\(notProtected.count) not protected") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            body = parts.joined(separator: ", ") + "."
        }
        notify(id: "pdfutils.unlock", title: "Remove Password", body: body)
    }

    private func unlockOne(_ input: URL) async -> UnlockOutcome {
        for attempt in 0..<3 {
            guard let password = promptPassword(for: input.lastPathComponent, wrongPrevious: attempt > 0) else {
                return .cancelled
            }
            // The PDFKit call runs on the work queue (the one-thread-at-a-time invariant), reached
            // by awaiting rather than the old `workQueue.sync`: syncing from the main actor stalled
            // the menu bar, prompts, and notifications behind every previously queued job — a
            // minutes-long beachball when a big Finder batch was ahead of the unlock. The output is
            // also named at write time now, so it can't collide with queued work's pending output.
            let outcome: Result<URL, Error> = await withCheckedContinuation { continuation in
                workQueue.async {
                    let output = Self.uniqueOutput(for: input, suffix: "unlocked")
                    do {
                        try PDFToolkit.removePassword(inputURL: input, outputURL: output, password: password)
                        continuation.resume(returning: .success(output))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            switch outcome {
            case .success(let output):
                return .success(output)
            case .failure(let error):
                if let op = error as? PDFOperationError {
                    switch op {
                    case .incorrectPassword: continue        // wrong password — prompt again
                    case .notEncrypted: return .notEncrypted // nothing to remove
                    default: return .failed(error.localizedDescription)
                    }
                }
                return .failed(error.localizedDescription)
            }
        }
        return .failed("the password was incorrect") // exhausted attempts
    }

    private func promptPassword(for fileName: String, wrongPrevious: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true) // bring the agent's dialog to the front
        let alert = NSAlert()
        alert.messageText = "Unlock “\(fileName)”"
        alert.informativeText = wrongPrevious
            ? "That password didn't work. Try again."
            : "Enter the password to remove protection from this PDF."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - Extract pages (interactive: needs a page-range prompt)

    private func runExtract(_ input: URL, log: ActivityLog) async {
        // Page count and lockedness in one queue visit: PDFKit stays off the main actor (the work
        // queue may be mid-operation on another document — the crash class the serial queue exists
        // to prevent), and a locked file is told the truth up front. It used to sail through this
        // check (locked documents report their real page count), walk the user through the range
        // prompt, and then fail with a generic notification.
        let probe: (count: Int, locked: Bool) = await withCheckedContinuation { continuation in
            workQueue.async {
                let doc = PDFDocument(url: input)
                continuation.resume(returning: (doc?.pageCount ?? 0, doc?.isLocked ?? false))
            }
        }
        if probe.locked {
            notify(id: "pdfutils.extract", title: "Extract Pages", body: "“\(input.lastPathComponent)” is password-protected.")
            showInfo(title: "“\(input.lastPathComponent)” is password-protected",
                     text: PDFOperationError.encryptedInput(input).errorDescription
                        ?? "Remove its password first, then try again.")
            return
        }
        guard probe.count > 0 else {
            notify(id: "pdfutils.extract", title: "Extract Pages", body: "Couldn't read “\(input.lastPathComponent)”.")
            showInfo(title: "Couldn't read “\(input.lastPathComponent)”",
                     text: "The PDF may be damaged.")
            return
        }
        guard let text = promptPageRange(for: input.lastPathComponent, pageCount: probe.count) else {
            // Cancelled — settle the "Getting ready…" notification so it doesn't linger as if work
            // were still coming.
            notify(id: "pdfutils.extract", title: "Extract Pages", body: "Cancelled — nothing was changed.")
            return
        }
        let indices: [Int]
        do {
            // Extract semantics: the whole entry is one output file, pages kept in the order typed.
            indices = try PageRangeParser.parse(text, pageCount: probe.count, emptyMeansAllPages: false, preserveOrder: true)
        } catch {
            notify(id: "pdfutils.extract", title: "Extract Pages", body: "Couldn't extract those pages.")
            showInfo(title: "Couldn't extract those pages",
                     text: (error as? PDFOperationError)?.errorDescription ?? error.localizedDescription)
            return
        }
        notify(id: "pdfutils.extract", title: "Extract Pages", body: startBody(1))
        activeBatches += 1
        workQueue.async { [self] in
            // Named at write time like compress/rotate/merge, not at prompt time: a name probed
            // while earlier queued work was still running could collide with the output that work
            // was about to write, and the later write clobbered the earlier file.
            let output = Self.uniqueOutput(for: input, suffix: "pages")
            do {
                try PDFToolkit.extract(inputURL: input, outputURL: output, pageIndices: indices)
                log.recordSaved(Tool.extract.title, to: output, bytes: Self.fileSize(of: output), detail: "\(indices.count) pages")
                finish(id: "pdfutils.extract", title: "Extract Pages", revealed: [output], failed: [])
            } catch {
                log.error("\(Tool.extract.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                finish(id: "pdfutils.extract", title: "Extract Pages", revealed: [], failed: ["extract"],
                       failureDetail: error.localizedDescription)
            }
        }
    }

    private func promptPageRange(for fileName: String, pageCount: Int) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Extract pages from “\(fileName)”"
        alert.informativeText = "Which pages? For example 1, 3-5. This PDF has \(pageCount) pages."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "1, 3-5"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - Output naming + notifications

    /// A non-clobbering output URL: "Name.pdf", then "Name 2.pdf", "Name 3.pdf", …
    private nonisolated static func uniqueOutput(for input: URL, suffix: String) -> URL {
        uniqueOutput(inDirectory: input.deletingLastPathComponent(),
                     name: "\(input.deletingPathExtension().lastPathComponent)-\(suffix)")
    }

    private nonisolated static func uniqueOutput(inDirectory dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(name).pdf")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n).pdf")
            n += 1
        }
        return candidate
    }

    /// Byte size of a just-written output, for the Activity Log's `(1.2 MB)` suffix. Best-effort — a
    /// nil size simply omits the suffix rather than failing the recording.
    private nonisolated static func fileSize(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private nonisolated func startBody(_ count: Int) -> String {
        count == 1 ? "Working…" : "Working on \(count) files…"
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Present banners even when the helper is the frontmost app — otherwise macOS suppresses the
    /// notification whenever we've just activated to show the unlock prompt.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
