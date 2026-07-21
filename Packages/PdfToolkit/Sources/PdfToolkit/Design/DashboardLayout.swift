import Foundation

/// How the dashboard arranges its tool catalog — a preset picked in Settings → Appearance. `categories`
/// groups tools under section headers (the default); `grid` is the flat adaptive tile grid with no
/// grouping; `list` is a compact one-row-per-tool table. Orthogonal to the glass/accent settings —
/// every layout renders the same tiles/rows, so it changes only the arrangement, not the styling.
public enum DashboardLayout: String, CaseIterable, Identifiable, Sendable {
    /// Tools grouped under category headers (Optimize, Organize pages, …). The default.
    case categories
    /// One flat adaptive grid of every tile, ungrouped.
    case grid
    /// A compact list: one dense row per tool.
    case list

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .categories: return "Categories"
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    public var detail: String {
        switch self {
        case .categories:
            return "Tools are grouped under category headers like Optimize and Organize pages."
        case .grid:
            return "Every tool in one even grid of tiles, with no category grouping."
        case .list:
            return "A compact list — one row per tool, denser than the grid."
        }
    }
}
