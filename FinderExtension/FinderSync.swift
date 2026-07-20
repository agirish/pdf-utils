import Cocoa
import FinderSync

/// The Finder Sync principal class. macOS instantiates it (by the ObjC name declared in
/// `NSExtensionPrincipalClass`) when the extension activates. We monitor the whole filesystem so
/// our contextual menu can appear for a PDF selected anywhere in Finder.
///
/// The extension is sandboxed (mandatory — macOS refuses to load an unsandboxed one), which means
/// it can't read or write the selected files itself. So it does no PDF work: it writes the request
/// into its own container and pings the resident menu-bar helper, which runs unsandboxed and does
/// the actual work.
@objc(PdfUtilsFinderSync)
final class PdfUtilsFinderSync: FIFinderSync {

    override init() {
        super.init()
        // Monitoring `/` is the standard trick for a utility (vs. a cloud provider that watches one
        // synced folder): it makes `menu(for:)` fire for a right-click anywhere. It grants no file
        // access — that's exactly why the work is handed off to the helper.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        diag("init")
    }

    /// Appends a line to a log inside the extension's own sandbox container
    /// (`~/Library/Containers/com.pdfutils.PdfUtils.FinderSync/Data/diag.log`). A deliberate dev aid:
    /// the unified log (`log show`) does not surface this sandboxed process in some environments, so
    /// this file is the only way to observe the extension's behavior.
    private func diag(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("diag.log")
        guard let data = "\(Date()) \(msg)\n".data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        // Finder is a separate process with no responder to validate our action, so default
        // auto-enabling would render the item disabled (visible but inert). Turn it off so the item
        // is always clickable; Finder then routes the action back to us.
        menu.autoenablesItems = false
        guard menuKind == .contextualMenuForItems else { return menu }

        let pdfs = selectedPDFs()
        guard !pdfs.isEmpty else { return menu }
        let n = pdfs.count

        menu.addItem(actionItem(n == 1 ? "Compress PDF" : "Compress \(n) PDFs",
                                #selector(compressPDFs(_:)), symbol: "doc.zipper"))
        // Offered for any PDF: the sandbox blocks us from reading the file AND its Spotlight
        // metadata (kMDItemSecurityMethod comes back nil for every file here), so we can't tell at
        // menu-build time whether a PDF is actually encrypted. The helper reports "not
        // password-protected" when there's nothing to remove.
        menu.addItem(actionItem(n == 1 ? "Remove Password…" : "Remove Password from \(n) PDFs…",
                                #selector(unlockPDFs(_:)), symbol: "lock.open"))

        // Rotate — a submenu of directions; no dialog needed (rotates every page). Applies to all
        // selected PDFs.
        let rotateItem = NSMenuItem(title: n == 1 ? "Rotate PDF" : "Rotate \(n) PDFs", action: nil, keyEquivalent: "")
        rotateItem.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
        let rotateSub = NSMenu(title: "Rotate")
        rotateSub.autoenablesItems = false
        rotateSub.addItem(actionItem("Rotate Right 90°", #selector(rotateRight(_:)), symbol: "rotate.right"))
        rotateSub.addItem(actionItem("Rotate Left 90°", #selector(rotateLeft(_:)), symbol: "rotate.left"))
        rotateSub.addItem(actionItem("Rotate 180°", #selector(rotate180(_:)), symbol: "arrow.uturn.down"))
        rotateItem.submenu = rotateSub
        menu.addItem(rotateItem)

        // Extract pages — single PDF only (a page range pulled from one document).
        if n == 1 {
            menu.addItem(actionItem("Extract Pages…", #selector(extractPages(_:)), symbol: "doc.on.doc"))
        }

        // Merge only makes sense for two or more.
        if n >= 2 {
            menu.addItem(actionItem("Merge \(n) PDFs", #selector(mergePDFs(_:)), symbol: "arrow.triangle.merge"))
        }
        return menu
    }

    /// Builds a menu item with no explicit target: the menu is serialized to Finder over XPC, so a
    /// `target` object can't cross the boundary. Finder dispatches the action selector back to this
    /// principal object by name.
    private func actionItem(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func selectedPDFs() -> [URL] {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    // MARK: - Action

    // NOT @MainActor: Finder dispatches this selector on a background XPC queue, so a main-actor
    // executor precondition would trap (EXC_BREAKPOINT) the moment it's called.
    @objc func compressPDFs(_ sender: AnyObject?) {
        let pdfs = selectedPDFs()
        guard !pdfs.isEmpty else { return }
        handOff(action: "compress", urls: pdfs)
    }

    @objc func unlockPDFs(_ sender: AnyObject?) {
        let pdfs = selectedPDFs()
        guard !pdfs.isEmpty else { return }
        handOff(action: "unlock", urls: pdfs)
    }

    @objc func mergePDFs(_ sender: AnyObject?) {
        let pdfs = selectedPDFs()
        guard pdfs.count >= 2 else { return }
        handOff(action: "merge", urls: pdfs)
    }

    @objc func rotateRight(_ sender: AnyObject?) { rotate(quarterTurns: 1) } // 90° clockwise
    @objc func rotateLeft(_ sender: AnyObject?) { rotate(quarterTurns: 3) }  // 90° counter-clockwise
    @objc func rotate180(_ sender: AnyObject?) { rotate(quarterTurns: 2) }

    private func rotate(quarterTurns: Int) {
        let pdfs = selectedPDFs()
        guard !pdfs.isEmpty else { return }
        handOff(action: "rotate", urls: pdfs, extra: ["quarterTurns": quarterTurns])
    }

    @objc func extractPages(_ sender: AnyObject?) {
        let pdfs = selectedPDFs()
        guard pdfs.count == 1 else { return }
        handOff(action: "extract", urls: pdfs)
    }

    /// Serialize the request into this extension's container (a path the unsandboxed helper can
    /// read) and ping the helper to carry it out. `extra` carries per-action parameters (e.g. the
    /// rotate direction).
    private func handOff(action: String, urls: [URL], extra: [String: Any] = [:]) {
        var command: [String: Any] = [
            "action": action,
            "paths": urls.map { $0.path },
            "ts": Date().timeIntervalSince1970,
        ]
        command.merge(extra) { _, new in new }
        let cmdURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("command.json")
        if let data = try? JSONSerialization.data(withJSONObject: command, options: [.prettyPrinted]) {
            do { try data.write(to: cmdURL) } catch { diag("command.json write failed: \(error)") }
        }
        // Ping the resident menu-bar helper via its URL scheme. LaunchServices delivers this to the
        // already-running helper (reliable — no dependence on "became active") or launches it if it
        // isn't running; either way the helper then reads command.json and does the work.
        let ping = URL(string: "pdfutils-helper://run")!
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false // the helper works in the background and reveals the result in Finder
        NSWorkspace.shared.open(ping, configuration: cfg) { _, error in
            if let error = error { self.diag("helper ping failed: \(error)") }
        }
    }
}
