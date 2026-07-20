import SwiftUI

/// The Help book's content: a searchable topic sidebar on the left and the selected article on the
/// right. Fixed size — the content is bounded, so the card doesn't need to resize. `RootView` wraps
/// this in the same glass-card chrome as the Settings and Quick Actions overlays, so all three read
/// as one system.
public struct HelpView: View {
    let onClose: () -> Void

    @State private var selectedTopicID: String
    @State private var query: String = ""

    /// - Parameter initialTopicID: the topic to open on. `nil` (or an unknown id) lands on the first
    ///   topic. `HelpPresenter` sets this before opening, which is how the dashboard "?" and each
    ///   tool's "?" navigate straight to the right article.
    public init(initialTopicID: String? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let fallback = HelpBook.sections.first?.topics.first?.id ?? ""
        let resolved = initialTopicID.flatMap { HelpBook.topic(id: $0) != nil ? $0 : nil }
        _selectedTopicID = State(initialValue: resolved ?? fallback)
    }

    private var results: [HelpBook.Section] { HelpBook.filteredSections(matching: query) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            Text("\(AppBrand.displayName) Help")
                .font(.headline)
            Spacer()
            CloseButton(action: onClose)
                .keyboardShortcut(.cancelAction)
                .help("Close Help")
                .accessibilityLabel("Close Help")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if results.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "No topics found")
                            .padding(.top, 8)
                    }
                    ForEach(results, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .kerning(0.4)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(section.topics, id: \.id) { topic in
                                topicRow(topic)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search Help", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }

    private func topicRow(_ topic: HelpBook.Topic) -> some View {
        let isSelected = topic.id == selectedTopicID
        // Text on the accent fill uses Design's luminance-derived pairing, not hardcoded white: under
        // a light accent (Amber, Cyan) white text falls below the contrast floor.
        let onAccent = Color.onFillLabel(.accentColor)
        return Button {
            selectedTopicID = topic.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: topic.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? onAccent : .secondary)
                Text(topic.title)
                    .foregroundStyle(isSelected ? onAccent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let topic = HelpBook.topic(id: selectedTopicID) {
            ScrollView {
                HelpArticleView(
                    topic: topic,
                    sectionTitle: HelpBook.sectionTitle(forTopicID: topic.id),
                    onSelectRelated: { selectedTopicID = $0 }
                )
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Only reachable if a search leaves the selection off-list; keep it graceful.
            EmptyStateView(icon: "book", title: "Choose a topic from the list.")
        }
    }
}

/// Renders one `HelpBook.Article`: an eyebrow + title + intro, the typed body blocks, and a row of
/// related-topic chips that jump the selection.
struct HelpArticleView: View {
    let topic: HelpBook.Topic
    let sectionTitle: String?
    let onSelectRelated: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let sectionTitle {
                    Text(sectionTitle)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .foregroundStyle(Color.accentColor)
                }
                Text(topic.title)
                    .font(.title2.weight(.semibold))
                Text(topic.article.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(topic.article.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }

            if !topic.article.related.isEmpty {
                relatedChips
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HelpBook.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 5)
                        Text(item)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .steps(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.onFillLabel(.accentColor))
                            .frame(width: 20, height: 20)
                            .background(Color.accentColor, in: Circle())
                        Text(item)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .controls(let controls):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(controls.enumerated()), id: \.offset) { index, control in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(control.name)
                            .font(.callout.weight(.semibold))
                        Text(control.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )

        case .tip(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var relatedChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            FlexibleChips(ids: topic.article.related, onSelect: onSelectRelated)
        }
        .padding(.top, 4)
    }
}

/// The related-topic chips. A simple wrapping row: each chip shows a real topic's title and jumps the
/// selection when clicked. Ids are validated by `HelpBookTests`, so a lookup miss here would be a test
/// failure, not a runtime surprise.
private struct FlexibleChips: View {
    let ids: [String]
    let onSelect: (String) -> Void

    var body: some View {
        // A wrapping flow so a long "Related" row doesn't overflow the fixed-width detail pane.
        FlowLayout(spacing: 8) {
            ForEach(ids, id: \.self) { id in
                if let topic = HelpBook.topic(id: id) {
                    Button {
                        onSelect(id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(topic.title)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .overlay(
                            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A minimal wrapping layout: places subviews left to right, moving to the next line when the current
/// one runs out of width. Used for the "Related" chip row so it reflows instead of clipping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
