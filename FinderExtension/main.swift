// The real entry point for this app-extension binary is `_NSExtensionMain`, which
// the linker is told to use via `-e _NSExtensionMain` (see Package.swift). At launch
// PlugInKit reads the bundle's Info.plist, finds `NSExtensionPrincipalClass`, and
// instantiates `PdfUtilsFinderSync` — none of the top-level code below runs.
//
// SwiftPM still requires an executable target to designate a `main.swift`, so this
// file exists only to satisfy that requirement.
import Foundation
