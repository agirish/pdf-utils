import Foundation

/// UserDefaults keys for app settings (mirrors a dedicated Settings module layout).
enum SettingsKeys {
    static let mainWindowBackground = "pdfutils.settings.mainWindowBackground"
    static let mergePreviewBackground = "pdfutils.settings.mergePreviewBackground"
    /// Longest edge in pixels when rasterizing redacted pages (persisted for Redact PDF).
    static let redactRasterLongEdge = "pdfutils.settings.redactRasterLongEdge"
    /// When true, run PDFKit on-device OCR on write so image pages get selectable text where still visible.
    static let redactEmbedOCR = "pdfutils.settings.redactEmbedOCR"
}
