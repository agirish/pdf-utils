import SwiftUI

/// The ⌘K command palette: a frosted, centered card (framed by its host to match the Settings
/// overlay) with a search field and a live, fuzzy-ranked list of actions. It owns only its transient
/// UI state — the query text and which row is highlighted — and hands every decision back out:
/// `onActivate` runs the chosen action (the host navigates / opens Settings / opens the log) and
/// `onClose` dismisses. Keyboard: ↑/↓ move the highlight, Return activates it, Esc closes; hovering
/// or clicking a row selects it. Ranking is the pure `rankedMatches` in `QuickActionSearch`.
public struct QuickActionsPalette: View {
    private let actions: [QuickAction]
    private let onActivate: (QuickAction) -> Void
    private let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    public init(
        actions: [QuickAction],
        onActivate: @escaping (QuickAction) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.actions = actions
        self.onActivate = onActivate
        self.onClose = onClose
    }

    private var results: [QuickAction] {
        rankedMatches(query: query, in: actions)
    }

    /// The highlight clamped to the current results, so a shrinking list never points past the end.
    private var clampedHighlight: Int {
        guard !results.isEmpty else { return 0 }
        return min(max(highlighted, 0), results.count - 1)
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 560, height: 420)
        // Esc closes even when focus has left the search field.
        .onExitCommand(perform: onClose)
        .task {
            // Focusing in the same run loop as the overlay's insertion is unreliable; let it settle.
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
            TextField("Search actions", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Search actions")
                // Claim the navigation keys here so the focused field doesn't swallow them. Returning
                // `.handled` only for these keys leaves ordinary typing untouched.
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.return) { activateHighlighted(); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
            keyHint
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onChange(of: query) { _, _ in
            // A new query rebuilds the list; snap the highlight back to the strongest match.
            highlighted = 0
        }
    }

    /// The subtle "⌘K" pill in the field, echoing the shortcut that raised the palette.
    private var keyHint: some View {
        Text("⌘K")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No matching actions")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                            Button {
                                onActivate(action)
                            } label: {
                                QuickActionRow(action: action, isHighlighted: index == clampedHighlight)
                            }
                            .buttonStyle(.plain)
                            .id(action.id)
                            // Mouse hover selects the row, matching the keyboard highlight.
                            .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, _ in
                    guard results.indices.contains(clampedHighlight) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(results[clampedHighlight].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(clampedHighlight + delta, 0), results.count - 1)
    }

    private func activateHighlighted() {
        guard results.indices.contains(clampedHighlight) else { return }
        onActivate(results[clampedHighlight])
    }
}

/// One row in the palette: the action's SF Symbol on an accent-tinted chip, its title and subtitle,
/// and a Return glyph on the highlighted row. The highlight washes the whole row in the action's own
/// accent, echoing the icon tint.
private struct QuickActionRow: View {
    let action: QuickAction
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(action.accent.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: action.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(action.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(action.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHighlighted ? action.accent.opacity(0.18) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.title). \(action.subtitle)")
    }
}

private extension QuickAction {
    /// The SF Symbol for the row: a tool's own glyph, or a fixed glyph for the Settings / log actions.
    var symbolName: String {
        switch kind {
        case .tool(let tool): return tool.symbolName
        case .settings: return "gearshape"
        case .activityLog: return "clock.arrow.circlepath"
        }
    }

    /// The row's accent: a tool's own color, or a neutral gray for the app-level actions. Tints the
    /// icon chip and washes the highlighted row.
    var accent: Color {
        switch kind {
        case .tool(let tool): return tool.accent
        case .settings, .activityLog: return .gray
        }
    }
}
