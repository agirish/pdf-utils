import Foundation

/// The buckets the dashboard groups tools into under the Categories layout. The order of the cases is
/// the order the sections appear, and `tools` fixes the order *within* a section — both are hand-set
/// (not derived from `Tool.allCases`) so the dashboard reads as a deliberately curated shelf rather
/// than declaration order. `Tool.category` is the authoritative membership map; `ToolCategoryTests`
/// pins the two together so a tool can never fall out of every section or land in two.
public enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    /// Make a file smaller or more useful without changing its pages. Compress, OCR.
    case optimize
    /// Rearrange, combine, or thin out the pages themselves. Merge, Split, Extract, …
    case organize
    /// Change how a page looks or add marks on top of it. Crop, Watermark, Fill & Sign, …
    case edit
    /// Lock a file down or scrub what it reveals. Redact, Protect, Clean Metadata.
    case secure

    public var id: String { rawValue }

    /// The section header shown on the dashboard.
    public var displayName: String {
        switch self {
        case .optimize: return "Optimize"
        case .organize: return "Organize pages"
        case .edit: return "Edit & annotate"
        case .secure: return "Secure & clean"
        }
    }

    /// The tools in this category, in the order they should appear under its header. Curated by hand
    /// so the most-reached-for tool leads each section; kept consistent with `Tool.category` by test.
    public var tools: [Tool] {
        switch self {
        case .optimize:
            return [.compress, .ocr]
        case .organize:
            return [.merge, .split, .extract, .reorder, .deletePages, .rotate]
        case .edit:
            return [.crop, .watermark, .fillSign, .imagesToPdf]
        case .secure:
            return [.redact, .protect, .metadata]
        }
    }
}
