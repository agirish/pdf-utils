import Foundation

extension Error {
    /// True when this error is the user dismissing a save/export panel (Cancel) rather than a real
    /// failure. `.fileExporter` reports a cancel as a Cocoa `userCancelled` error; the Activity Log
    /// records genuine failures, not cancellations, so save-sites skip logging when this is true.
    var isUserCancelled: Bool {
        let nsError = self as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
