import Foundation

/// UserDefaults keys for app settings (mirrors a dedicated Settings module layout).
public enum SettingsKeys {
    public static let mainWindowBackground = "pdfutils.settings.mainWindowBackground"
    public static let mergePreviewBackground = "pdfutils.settings.mergePreviewBackground"
    /// Longest edge in pixels when rasterizing redacted pages (persisted for Redact PDF).
    public static let redactRasterLongEdge = "pdfutils.settings.redactRasterLongEdge"
}
