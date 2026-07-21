import Foundation

/// Resolves the user's custom *within-category* tool order to and from its persisted string form
/// (stored via `SettingsKeys.dashboardToolOrder`).
///
/// The format is a set of per-category segments joined by `;`, each `category:tool1,tool2,…` — for
/// example `organize:split,merge;edit:watermark,crop`. Only categories the user has actually
/// rearranged need appear; an absent category keeps its curated ``ToolCategory/tools`` order.
///
/// Like ``ToolCategoryOrder`` this resolver is deliberately forgiving so the stored value can never
/// desync from the code: unknown tokens, duplicates, and tools that don't belong to the segment's
/// category are dropped, and any of the category's tools the string didn't mention are appended in
/// canonical order. So `resolve(_:for:)` always returns exactly that category's full tool set, once
/// each — which means adding a tool to a category later makes it appear at the end of a customized
/// section rather than vanishing, and a moved/removed one simply falls away.
public enum ToolOrder {
    /// That `category`'s tools in the user's saved order, always resolved to the category's full,
    /// deduplicated membership (canonical order for anything the stored string didn't pin).
    public static func resolve(_ raw: String, for category: ToolCategory) -> [Tool] {
        let listed = parse(raw)[category] ?? []
        var result: [Tool] = []
        var seen = Set<Tool>()
        for tool in listed where tool.category == category && !seen.contains(tool) {
            result.append(tool)
            seen.insert(tool)
        }
        // Append any of this category's tools the stored string didn't mention, in canonical order.
        for tool in category.tools where !seen.contains(tool) {
            result.append(tool)
        }
        return result
    }

    /// The stored string with `category`'s order replaced by `tools`. A segment that matches the
    /// canonical order is dropped rather than stored, so the persisted value stays empty until an
    /// order actually differs from the default (and `isDefault` can stay simple).
    public static func replacing(_ category: ToolCategory, with tools: [Tool], in raw: String) -> String {
        var map = parse(raw)
        let normalized = resolveOrder(tools, for: category)
        if normalized == category.tools {
            map[category] = nil
        } else {
            map[category] = normalized
        }
        return serialize(map)
    }

    /// The stored string after moving `tool` one slot within its category — the keyboard/VoiceOver
    /// path that mirrors a drag. A no-op if it's already at that end.
    public static func moving(_ tool: Tool, _ direction: ToolCategoryOrder.MoveDirection, in raw: String) -> String {
        let category = tool.category
        var order = resolve(raw, for: category)
        guard let index = order.firstIndex(of: tool) else { return raw }
        let target = index + direction.offset
        guard order.indices.contains(target) else { return raw }
        order.swapAt(index, target)
        return replacing(category, with: order, in: raw)
    }

    /// Whether the stored string leaves every category in its canonical order (so callers can fold a
    /// "Reset" affordance together with ``ToolCategoryOrder``). An empty string is the default.
    public static func isDefault(_ raw: String) -> Bool {
        let map = parse(raw)
        return map.allSatisfy { category, tools in resolveOrder(tools, for: category) == category.tools }
    }

    // MARK: - Encoding

    /// A category's raw token list filtered to its valid members (deduped, foreign/unknown dropped),
    /// with the rest of its tools appended canonically — the shared core of `resolve` and `replacing`.
    private static func resolveOrder(_ tools: [Tool], for category: ToolCategory) -> [Tool] {
        var result: [Tool] = []
        var seen = Set<Tool>()
        for tool in tools where tool.category == category && !seen.contains(tool) {
            result.append(tool)
            seen.insert(tool)
        }
        for tool in category.tools where !seen.contains(tool) {
            result.append(tool)
        }
        return result
    }

    private static func parse(_ raw: String) -> [ToolCategory: [Tool]] {
        var map: [ToolCategory: [Tool]] = [:]
        for segment in raw.split(separator: ";") {
            let parts = segment.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let category = ToolCategory(rawValue: parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            let tools = parts[1].split(separator: ",").compactMap {
                Tool(rawValue: $0.trimmingCharacters(in: .whitespaces))
            }
            guard !tools.isEmpty else { continue }
            // Last segment wins if a category is (invalidly) listed twice.
            map[category] = tools
        }
        return map
    }

    private static func serialize(_ map: [ToolCategory: [Tool]]) -> String {
        // Emit in canonical category order so the stored string is stable regardless of edit order.
        ToolCategory.allCases.compactMap { category -> String? in
            guard let tools = map[category], !tools.isEmpty else { return nil }
            return "\(category.rawValue):\(tools.map(\.rawValue).joined(separator: ","))"
        }
        .joined(separator: ";")
    }
}
