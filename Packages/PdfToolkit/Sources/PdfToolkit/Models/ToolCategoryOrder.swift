import Foundation

/// Resolves the user's custom dashboard category order to and from its persisted string form (a
/// comma-joined list of ``ToolCategory`` raw values, stored via `SettingsKeys.dashboardCategoryOrder`).
///
/// The resolver is deliberately forgiving so the stored value can never desync from the code: unknown
/// or duplicate tokens are dropped, and any category missing from the string is appended in canonical
/// (`allCases`) order. So `resolve` always returns exactly the full set of categories, once each —
/// which means adding a new category later makes it appear at the end of a customized order rather than
/// vanishing, and a renamed/removed one simply falls away.
public enum ToolCategoryOrder {
    /// The persisted order parsed into a valid, complete list of categories.
    public static func resolve(_ raw: String) -> [ToolCategory] {
        var result: [ToolCategory] = []
        var seen = Set<ToolCategory>()
        for token in raw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let category = ToolCategory(rawValue: trimmed), !seen.contains(category) else { continue }
            result.append(category)
            seen.insert(category)
        }
        // Append any categories the stored string didn't mention, in canonical order.
        for category in ToolCategory.allCases where !seen.contains(category) {
            result.append(category)
        }
        return result
    }

    /// An order serialized to the persisted string form.
    public static func serialize(_ order: [ToolCategory]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// Whether `order` is the canonical default (so callers can hide a "Reset" affordance). An empty
    /// stored string resolves to the default, so this is true for it too.
    public static func isDefault(_ order: [ToolCategory]) -> Bool {
        order == ToolCategory.allCases
    }

    /// `order` with `category` moved one slot in `direction`, or unchanged if it's already at that end.
    /// Operates on the resolved order so the result is always complete and safe to serialize.
    public static func moving(_ category: ToolCategory, _ direction: MoveDirection, in order: [ToolCategory]) -> [ToolCategory] {
        guard let index = order.firstIndex(of: category) else { return order }
        let target = index + direction.offset
        guard order.indices.contains(target) else { return order }
        var next = order
        next.swapAt(index, target)
        return next
    }

    public enum MoveDirection {
        case up, down
        var offset: Int { self == .up ? -1 : 1 }
    }
}
