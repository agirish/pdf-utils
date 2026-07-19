import Foundation

/// UserDefaults keys for app settings (mirrors a dedicated Settings module layout).
///
/// Every string here is a persisted contract: renaming one silently resets that preference for
/// existing users, so `SettingsValueTypesTests` pins the literals.
public enum SettingsKeys {
    public static let mainWindowBackground = "pdfutils.settings.mainWindowBackground"
    public static let mergePreviewBackground = "pdfutils.settings.mergePreviewBackground"
    /// Longest edge in pixels when rasterizing redacted pages (persisted for Redact PDF).
    public static let redactRasterLongEdge = "pdfutils.settings.redactRasterLongEdge"

    // MARK: Files tab

    /// What to do with a file once it's saved (an ``AfterExportAction`` raw value).
    public static let afterExportAction = "pdfutils.settings.afterExportAction"
    /// Where tool output goes (a ``SaveLocation`` raw value): a save dialog, or beside the source.
    public static let saveLocation = "pdfutils.settings.saveLocation"
    /// When true, output names get a tool suffix (`Report-compressed.pdf`); off keeps the source stem.
    public static let appendFilenameSuffix = "pdfutils.settings.appendFilenameSuffix"
    /// When true, restore the last opened tool on launch instead of the dashboard.
    public static let reopenLastTool = "pdfutils.settings.reopenLastTool"
    /// The last tool the user opened (a ``Tool`` raw value); drives ``reopenLastTool``.
    public static let lastToolUsed = "pdfutils.settings.lastToolUsed"

    // MARK: Advanced tab

    /// When true, saved PDFs have their document info (author, title, dates) cleared.
    public static let stripMetadataOnExport = "pdfutils.settings.stripMetadataOnExport"
    /// Starting quality (0.2…1) for the Compress tool's slider; also its last-used value.
    public static let defaultCompressionQuality = "pdfutils.settings.defaultCompressionQuality"
}
