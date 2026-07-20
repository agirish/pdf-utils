import Cocoa

// A normal (non-extension) agent app: standard entry point, no Dock icon. `.accessory`
// keeps it out of the Dock and the app menu — it lives only in the menu bar.
let app = NSApplication.shared
let delegate = HelperAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
