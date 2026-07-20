import Cocoa
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
final class HelperAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private static let helperBundleID = "com.pdfutils.PdfUtils.Helper"
    private static let mainAppBundleID = "com.pdfutils.PdfUtils"

    /// The extension drops its request here (its own sandbox container, which we can read).
    private let commandURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.pdfutils.PdfUtils.FinderSync/Data/command.json")

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
        return menu
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
            statusItem?.menu = buildMenu()
            return
        }
        statusItem?.menu = buildMenu()
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
        guard let data = try? Data(contentsOf: commandURL) else { return }
        try? FileManager.default.removeItem(at: commandURL) // consume so we never reprocess
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String,
              let paths = obj["paths"] as? [String], !paths.isEmpty else { return }
        let inputs = paths.map { URL(fileURLWithPath: $0) }
        // Captured on the main actor so the background work queue can record into the shared log
        // without touching the main-actor-isolated `.shared` accessor off-thread (the logging methods
        // themselves are nonisolated). Attribution matches the in-app tools so the log reads uniformly
        // regardless of whether an operation started in the app or from a Finder right-click.
        let log = ActivityLog.shared

        switch action {
        case "compress":
            notify(id: "pdfutils.compress", title: "Compress PDF", body: startBody(inputs.count))
            workQueue.async { [self] in
                var revealed: [URL] = []
                var failed: [String] = []
                for input in inputs {
                    let output = Self.uniqueOutput(for: input, suffix: "compressed")
                    do {
                        try PDFToolkit.compress(inputURL: input, outputURL: output, quality: 0.6)
                        revealed.append(output)
                        log.recordSaved(Tool.compress.title, to: output, bytes: Self.fileSize(of: output))
                    } catch {
                        failed.append(input.lastPathComponent)
                        log.error("\(Tool.compress.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                finish(id: "pdfutils.compress", title: "Compress PDF", revealed: revealed, failed: failed)
            }

        case "merge":
            notify(id: "pdfutils.merge", title: "Merge PDFs", body: startBody(inputs.count))
            workQueue.async { [self] in
                // Combined in Finder's selection order, into the first file's folder.
                let output = Self.uniqueOutput(inDirectory: inputs[0].deletingLastPathComponent(), name: "Merged")
                do {
                    try PDFToolkit.merge(inputURLs: inputs, outputURL: output)
                    log.recordSaved(Tool.merge.title, to: output, bytes: Self.fileSize(of: output), detail: "\(inputs.count) files")
                    finish(id: "pdfutils.merge", title: "Merge PDFs", revealed: [output], failed: [])
                } catch {
                    log.error("\(Tool.merge.title) failed: \(error.localizedDescription)")
                    finish(id: "pdfutils.merge", title: "Merge PDFs", revealed: [], failed: ["merge"])
                }
            }

        case "rotate":
            let turns = obj["quarterTurns"] as? Int ?? 1
            notify(id: "pdfutils.rotate", title: "Rotate PDF", body: startBody(inputs.count))
            workQueue.async { [self] in
                var revealed: [URL] = []
                var failed: [String] = []
                for input in inputs {
                    let count = PDFToolkit.pageCount(at: input) ?? 0
                    let output = Self.uniqueOutput(for: input, suffix: "rotated")
                    do {
                        try PDFToolkit.rotate(inputURL: input, outputURL: output, pageIndices: Array(0..<count), quarterTurns: turns)
                        revealed.append(output)
                        log.recordSaved(Tool.rotate.title, to: output, bytes: Self.fileSize(of: output))
                    } catch {
                        failed.append(input.lastPathComponent)
                        log.error("\(Tool.rotate.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                finish(id: "pdfutils.rotate", title: "Rotate PDF", revealed: revealed, failed: failed)
            }

        case "extract":
            if let input = inputs.first { runExtract(input, log: log) }

        case "unlock":
            runUnlock(inputs)

        default:
            break
        }
    }

    /// Hops back to the main actor to reveal results in Finder and post the completion notice.
    private nonisolated func finish(id: String, title: String, revealed: [URL], failed: [String]) {
        Task { @MainActor in
            if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
            flashStatusIcon(success: failed.isEmpty)
            let body: String
            if failed.isEmpty {
                body = revealed.count <= 1 ? "Done — revealed in Finder." : "Done — \(revealed.count) files revealed in Finder."
            } else if revealed.isEmpty {
                body = "Couldn't complete. The file may be open elsewhere or damaged."
            } else {
                body = "\(revealed.count) done, \(failed.count) failed."
            }
            notify(id: id, title: title, body: body)
        }
    }

    // MARK: - Remove password (interactive: needs a prompt, so it runs on the main actor)

    private enum UnlockOutcome { case success(URL), notEncrypted, failed(String), cancelled }

    private func runUnlock(_ inputs: [URL]) {
        var revealed: [URL] = []
        var notProtected: [String] = []
        var failed: [String] = []
        loop: for input in inputs {
            switch unlockOne(input) {
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

    private func unlockOne(_ input: URL) -> UnlockOutcome {
        for attempt in 0..<3 {
            guard let password = promptPassword(for: input.lastPathComponent, wrongPrevious: attempt > 0) else {
                return .cancelled
            }
            let output = Self.uniqueOutput(for: input, suffix: "unlocked")
            var thrown: Error?
            // Serialize the PDFKit call with the background work queue, honoring the one-thread-at-a-time
            // invariant even though we're driving it from the main actor for the prompt.
            workQueue.sync {
                do { try PDFToolkit.removePassword(inputURL: input, outputURL: output, password: password) }
                catch { thrown = error }
            }
            guard let error = thrown else { return .success(output) }
            if let op = error as? PDFOperationError {
                switch op {
                case .incorrectPassword: continue        // wrong password — prompt again
                case .notEncrypted: return .notEncrypted // nothing to remove
                default: return .failed(error.localizedDescription)
                }
            }
            return .failed(error.localizedDescription)
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

    private func runExtract(_ input: URL, log: ActivityLog) {
        guard let count = PDFToolkit.pageCount(at: input), count > 0 else {
            showInfo(title: "Couldn't read “\(input.lastPathComponent)”",
                     text: "The PDF may be damaged or password-protected.")
            return
        }
        guard let text = promptPageRange(for: input.lastPathComponent, pageCount: count) else { return } // cancelled
        let indices: [Int]
        do {
            // Extract semantics: the whole entry is one output file, pages kept in the order typed.
            indices = try PageRangeParser.parse(text, pageCount: count, emptyMeansAllPages: false, preserveOrder: true)
        } catch {
            showInfo(title: "Couldn't extract those pages",
                     text: (error as? PDFOperationError)?.errorDescription ?? error.localizedDescription)
            return
        }
        let output = Self.uniqueOutput(for: input, suffix: "pages")
        notify(id: "pdfutils.extract", title: "Extract Pages", body: startBody(1))
        workQueue.async { [self] in
            do {
                try PDFToolkit.extract(inputURL: input, outputURL: output, pageIndices: indices)
                log.recordSaved(Tool.extract.title, to: output, bytes: Self.fileSize(of: output), detail: "\(indices.count) pages")
                finish(id: "pdfutils.extract", title: "Extract Pages", revealed: [output], failed: [])
            } catch {
                log.error("\(Tool.extract.title) failed for \(input.lastPathComponent): \(error.localizedDescription)")
                finish(id: "pdfutils.extract", title: "Extract Pages", revealed: [], failed: ["extract"])
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
