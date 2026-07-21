import Foundation

/// Resolves the user's pinned tools to and from their persisted string form (a comma-joined list of
/// ``Tool`` raw values, in pin order, stored via `SettingsKeys.dashboardPinnedTools`).
///
/// Pinning cross-cuts the categories, so — unlike ``ToolCategoryOrder`` and ``ToolOrder`` — this is a
/// *subset*, not a permutation of the whole catalog: the default is empty (nothing pinned), and
/// `resolve` never appends the tools you didn't pin. It stays forgiving in the same spirit, though:
/// unknown or duplicate tokens are dropped, so the stored value can't desync from the code (a removed
/// tool simply falls out of the pinned shelf).
///
/// The order is meaningful: it's the order pinned tiles appear in the Categories view's Pinned section
/// and the "first few" in the Grid and List layouts.
public enum PinnedTools {
    /// The persisted pins parsed into a valid, ordered, duplicate-free list of tools.
    public static func resolve(_ raw: String) -> [Tool] {
        var result: [Tool] = []
        var seen = Set<Tool>()
        for token in raw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let tool = Tool(rawValue: trimmed), !seen.contains(tool) else { continue }
            result.append(tool)
            seen.insert(tool)
        }
        return result
    }

    /// A pinned list serialized to the persisted string form.
    public static func serialize(_ tools: [Tool]) -> String {
        tools.map(\.rawValue).joined(separator: ",")
    }

    /// Whether `tool` is currently pinned.
    public static func contains(_ tool: Tool, in raw: String) -> Bool {
        resolve(raw).contains(tool)
    }

    /// The stored string with `tool` pinned (appended to the end) if it wasn't, or unpinned if it was.
    public static func toggling(_ tool: Tool, in raw: String) -> String {
        var pins = resolve(raw)
        if let index = pins.firstIndex(of: tool) {
            pins.remove(at: index)
        } else {
            pins.append(tool)
        }
        return serialize(pins)
    }

    /// The stored string after moving `tool` one slot within the pinned shelf — the keyboard/VoiceOver
    /// path that mirrors a drag. A no-op if `tool` isn't pinned or is already at that end.
    public static func moving(_ tool: Tool, _ direction: ToolCategoryOrder.MoveDirection, in raw: String) -> String {
        var pins = resolve(raw)
        guard let index = pins.firstIndex(of: tool) else { return raw }
        let target = index + direction.offset
        guard pins.indices.contains(target) else { return raw }
        pins.swapAt(index, target)
        return serialize(pins)
    }
}
