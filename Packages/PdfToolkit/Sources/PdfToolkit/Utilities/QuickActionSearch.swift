import Foundation

/// What a Quick Action does when activated. The palette lives in the app layer (`RootView`) because
/// every case drives host-owned state — pushing onto the tool navigation path, raising the Settings
/// overlay on a tab, or opening the Activity Log window — so `QuickActionKind` only *describes* the
/// destination and leaves the doing to the host. Deliberately free of SwiftUI so the ranking below
/// stays a pure, unit-testable value transform.
public enum QuickActionKind: Equatable, Hashable {
    /// Navigate to a tool screen.
    case tool(Tool)
    /// Open the Settings overlay: `nil` opens it on the last-used tab, otherwise on the given tab.
    case settings(SettingsTab?)
    /// Open the Activity Log window.
    case activityLog
}

/// One entry in the ⌘K command palette: a stable `id`, the `title`/`subtitle` shown in the row (and
/// searched over), and the `kind` describing what activating it does. Kept tiny and free of
/// presentation (SF Symbol, accent) — the palette derives those from `kind` — so this stays a plain
/// value the ranking can be tested against.
public struct QuickAction: Identifiable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: QuickActionKind

    public init(id: String, title: String, subtitle: String, kind: QuickActionKind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

public extension QuickAction {
    /// The full catalog the palette searches: every tool, then Settings (general + each tab), then
    /// the Activity Log. A computed property, not a stored `static let`, so it needs no `Sendable`
    /// promise from `Tool` (which this feature must not touch) under Swift 6's global-isolation rules.
    /// The order here is the empty-query order, so tools — the common target — come first.
    static var catalog: [QuickAction] {
        var actions = Tool.allCases.map { tool in
            QuickAction(
                id: "tool.\(tool.rawValue)",
                title: tool.title,
                subtitle: tool.subtitle,
                kind: .tool(tool)
            )
        }
        actions.append(contentsOf: [
            QuickAction(
                id: "settings",
                title: "Open Settings",
                subtitle: "Preferences for files, appearance, and more",
                kind: .settings(nil)
            ),
            // NB: the tool entries above are what `toolCatalog` (and so the dashboard search) ranks over.
            QuickAction(
                id: "settings.files",
                title: "Files Settings",
                subtitle: "Save location, after export, and filenames",
                kind: .settings(.files)
            ),
            QuickAction(
                id: "settings.appearance",
                title: "Appearance Settings",
                subtitle: "Theme, accent color, and glass effect",
                kind: .settings(.appearance)
            ),
            QuickAction(
                id: "settings.advanced",
                title: "Advanced Settings",
                subtitle: "Compression, logging, and privacy",
                kind: .settings(.advanced)
            ),
            QuickAction(
                id: "activity-log",
                title: "Open Activity Log",
                subtitle: "Review recent operations and errors",
                kind: .activityLog
            ),
        ])
        return actions
    }

    /// The catalog narrowed to tool destinations — the corpus the dashboard search ranks over. Sharing
    /// the catalog's tool entries (same titles/subtitles) is what keeps dashboard search and the ⌘K
    /// palette consistent. Computed, like `catalog`, so it makes no `Sendable` demand of `Tool`.
    static var toolCatalog: [QuickAction] {
        catalog.filter { action in
            if case .tool = action.kind { return true }
            return false
        }
    }
}

/// Tools whose title/subtitle match `query`, fuzzy-ranked exactly as the ⌘K palette ranks its actions
/// (`rankedMatches` over `QuickAction.toolCatalog`) and flattened to the tools themselves, non-matches
/// dropped. An empty/whitespace query returns every tool in catalog order. This is what the dashboard
/// search field calls, so the two search surfaces behave identically. Pure and unit-tested.
public func rankedToolMatches(query: String) -> [Tool] {
    rankedMatches(query: query, in: QuickAction.toolCatalog).compactMap { action in
        if case let .tool(tool) = action.kind { return tool }
        return nil
    }
}

/// Ranks `actions` against `query` for the ⌘K palette. An empty query returns every action in its
/// catalog order. Otherwise each action is scored on how its title and subtitle match the query —
/// prefix beats substring beats subsequence, and any title match outranks a subtitle-only one — and
/// non-matches are dropped. Matching is case-insensitive; ties keep catalog order so the list stays
/// stable as the user types. Pure and synchronous by design: this is the unit-tested core, with all
/// presentation and navigation handled by the palette view and its host.
public func rankedMatches(query: String, in actions: [QuickAction]) -> [QuickAction] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return actions }

    return actions.enumerated()
        .compactMap { index, action -> (action: QuickAction, score: Int, index: Int)? in
            let title = matchTier(needle, in: action.title.lowercased())
            let subtitle = matchTier(needle, in: action.subtitle.lowercased())
            guard title > 0 || subtitle > 0 else { return nil }
            // The title tier dominates: weighting it ×4 (its own max is 3) guarantees any title
            // match sorts above a subtitle-only match, with the subtitle tier breaking ties.
            return (action, title * 4 + subtitle, index)
        }
        .sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }
        .map(\.action)
}

/// How strongly `needle` matches `haystack` (both already lowercased): 3 prefix, 2 substring,
/// 1 subsequence (letters in order but not necessarily adjacent, e.g. "cmp" in "compress"), 0 none.
/// The checks nest — a prefix is also a substring is also a subsequence — so the first that holds is
/// the strongest tier.
private func matchTier(_ needle: String, in haystack: String) -> Int {
    if haystack.hasPrefix(needle) { return 3 }
    if haystack.contains(needle) { return 2 }
    if isSubsequence(needle, of: haystack) { return 1 }
    return 0
}

/// Whether every character of `needle` appears in `haystack` in order (not necessarily adjacent).
private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var cursor = needle.startIndex
    guard cursor != needle.endIndex else { return true }
    for character in haystack where character == needle[cursor] {
        cursor = needle.index(after: cursor)
        if cursor == needle.endIndex { return true }
    }
    return false
}
