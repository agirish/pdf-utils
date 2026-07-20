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
final class HelperAppDelegate: NSObject, NSApplicationDelegate {

    private static let helperBundleID = "com.pdfutils.PdfUtils.Helper"
    private static let mainAppBundleID = "com.pdfutils.PdfUtils"

    /// The extension drops its request here (its own sandbox container, which we can read).
    private let commandURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.pdfutils.PdfUtils.FinderSync/Data/command.json")

    /// Serial so Finder-triggered PDF work never runs PDFKit on two threads at once — the same
    /// invariant the in-app tools honor via `PDFBackgroundWork`.
    private let workQueue = DispatchQueue(label: "org.pdfutils.helper.work", qos: .userInitiated)

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Receive pdfutils-helper:// URLs (the extension's ping) whether we're cold-launched or
        // already running.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        setUpStatusItem()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // First launch: make ourselves resident across logins (best-effort; the menu toggles it).
        enableLoginItemIfFirstRun()

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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "PDF Utils", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(title: "Open PDF Utils", action: #selector(openMainApp)))
        let login = item(title: "Start at Login", action: #selector(toggleLoginItem))
        login.state = (loginItemStatus == .enabled) ? .on : .off
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

    private var loginItemStatus: SMAppService.Status {
        SMAppService.loginItem(identifier: Self.helperBundleID).status
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.loginItem(identifier: Self.helperBundleID)
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("[Helper] login-item toggle failed: \(error)")
        }
        statusItem?.menu = buildMenu() // reflect new state
    }

    private func enableLoginItemIfFirstRun() {
        let service = SMAppService.loginItem(identifier: Self.helperBundleID)
        guard service.status == .notRegistered else { return }
        do { try service.register() } catch { NSLog("[Helper] initial login-item registration failed: \(error)") }
        statusItem?.menu = buildMenu()
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

        notify(id: "pdfutils.\(action)", title: verb(for: action), body: bodyForStart(count: paths.count))

        workQueue.async { [self] in
            var ok: [URL] = []
            var failedNames: [String] = []
            for path in paths {
                let input = URL(fileURLWithPath: path)
                let base = input.deletingPathExtension().lastPathComponent
                let output = input.deletingLastPathComponent().appendingPathComponent("\(base)-compressed.pdf")
                do {
                    switch action {
                    case "compress":
                        try PDFToolkit.compress(inputURL: input, outputURL: output, quality: 0.6)
                        ok.append(output)
                    default:
                        failedNames.append(input.lastPathComponent)
                    }
                } catch {
                    failedNames.append(input.lastPathComponent)
                }
            }
            let revealed = ok
            let failures = failedNames
            Task { @MainActor in
                if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
                notifyResult(action: action, succeeded: revealed.count, failed: failures)
            }
        }
    }

    // MARK: - Notifications

    private func verb(for action: String) -> String {
        switch action {
        case "compress": return "Compressing PDF"
        default: return "PDF Utils"
        }
    }

    private func bodyForStart(count: Int) -> String {
        count == 1 ? "Working…" : "Working on \(count) files…"
    }

    private func notifyResult(action: String, succeeded: Int, failed: [String]) {
        let body: String
        if failed.isEmpty {
            body = succeeded == 1 ? "Done — revealed in Finder." : "Done — \(succeeded) files revealed in Finder."
        } else if succeeded == 0 {
            body = "Couldn't process \(failed.joined(separator: ", "))."
        } else {
            body = "\(succeeded) done, \(failed.count) failed."
        }
        notify(id: "pdfutils.\(action)", title: verb(for: action), body: body)
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
