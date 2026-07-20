import Foundation

/// The content behind Help ▸ PDF Utils Help (⌘?). Pure data — a handful of sections, each a list of
/// topics, each topic a short article of typed blocks — kept UI-free so `HelpBookTests` can pin the
/// shape (unique ids, resolvable cross-links, no empty copy) without a view.
///
/// The eleven tool articles are *derived* from each `Tool.helpContent`, so the words a user reads in
/// the Help book and the words that used to live in the per-tool sheet are one and the same source —
/// update `ToolHelpContent` and both move together. The non-tool topics (getting started, settings,
/// safety) are authored here directly. Deliberately no PDFKit dependency: this is words about the
/// app, not the app's logic.
enum HelpBook {
    /// One rendered piece of an article. The renderer owns layout; the data owns words.
    enum Block: Equatable {
        /// A paragraph of running text.
        case paragraph(String)
        /// A short list of points, each rendered as its own row.
        case bullets([String])
        /// An ordered how-to: each string is one numbered step.
        case steps([String])
        /// A control glossary: each entry names a button/field and explains it.
        case controls([Control])
        /// A highlighted aside — a tip or a safety note — set off with a bulb.
        case tip(String)

        /// Flattened text of the block, for the sidebar search index.
        var searchableText: String {
            switch self {
            case .paragraph(let s), .tip(let s):
                return s
            case .bullets(let items), .steps(let items):
                return items.joined(separator: " ")
            case .controls(let items):
                return items.map { "\($0.name) \($0.detail)" }.joined(separator: " ")
            }
        }
    }

    /// One row of a control glossary — a control's name and what it does.
    struct Control: Equatable {
        let name: String
        let detail: String
    }

    /// A single help article, addressed by the `Topic` that owns it.
    struct Article: Equatable {
        /// The one-line summary under the title.
        let intro: String
        /// The body, top to bottom.
        let blocks: [Block]
        /// Ids of related topics, rendered as tappable chips. Every id must resolve to a real topic —
        /// `HelpBookTests` enforces it.
        let related: [String]

        init(intro: String, blocks: [Block] = [], related: [String] = []) {
            self.intro = intro
            self.blocks = blocks
            self.related = related
        }
    }

    /// A navigable entry in the sidebar.
    struct Topic: Equatable {
        /// Stable identifier used for selection and cross-links — never shown to the user.
        let id: String
        let title: String
        let systemImage: String
        let article: Article
    }

    /// A titled group of topics in the sidebar.
    struct Section: Equatable {
        let title: String
        let topics: [Topic]
    }

    // MARK: Content

    static let sections: [Section] = [
        Section(title: "Getting started", topics: [
            Topic(id: "welcome", title: "What is \(AppBrand.displayName)?", systemImage: "sparkles", article: Article(
                intro: "\(AppBrand.displayName) is a set of focused PDF tools that run entirely on your Mac. Pick a tool, choose the PDFs to work on, and it writes a brand-new file — your originals are never touched.",
                blocks: [
                    .paragraph("Each tool does one job — compress, merge, split, sign, protect, and more. Nothing is uploaded to a server; every page is processed locally and the result is saved through the system save sheet, so you choose the name and folder."),
                    .bullets([
                        "Pick a tool from the dashboard grid.",
                        "Add the PDF (or PDFs) you want to work on.",
                        "Adjust the options, then save the new file.",
                    ]),
                    .tip("Your source file is only overwritten if you deliberately save on top of it. Otherwise every tool produces a separate new PDF."),
                ],
                related: ["choosing-files", "the-tools", "privacy-safety"]
            )),
            Topic(id: "choosing-files", title: "Opening your PDFs", systemImage: "doc.badge.plus", article: Article(
                intro: "Most tools start the same way: point them at a PDF. You can browse for it, or drag it straight from Finder.",
                blocks: [
                    .bullets([
                        "Click Choose… (or Add PDFs… in Merge) to pick files with the system open panel.",
                        "Or drag one or more PDFs from Finder onto the tool's drop area.",
                        "macOS grants access to exactly the files you pick, so the tools stay sandboxed.",
                    ]),
                    .tip("If a tool says it can't access a file, choose it again with Choose… or Add PDFs… so macOS can re-grant access."),
                ],
                related: ["welcome", "the-tools"]
            )),
            Topic(id: "the-tools", title: "The tools at a glance", systemImage: "square.grid.2x2", article: Article(
                intro: "Every tool lives on the dashboard. Here's how they group by what you're trying to do.",
                blocks: [
                    .bullets([
                        "Combine & split — Merge stacks PDFs into one; Split and Extract pull files or pages out; Images to PDF turns pictures into a document.",
                        "Arrange pages — Reorder, Delete Pages, Rotate, and Crop rework the pages of a single PDF.",
                        "Compress & watermark — Compress shrinks a file; Watermark stamps text across every page.",
                        "Secure & sign — Password Protect encrypts, Redact removes content for good, Fill & Sign adds text and a signature, and Clean Metadata strips hidden document info.",
                    ]),
                    .tip("Press ⌘K anywhere to jump straight to a tool without returning to the dashboard."),
                ],
                related: ["tool-merge", "tool-compress", "tool-protect"]
            )),
        ]),
        Section(title: "Combine & split", topics: [
            toolTopic(.merge),
            toolTopic(.split),
            toolTopic(.extract),
            toolTopic(.imagesToPdf),
        ]),
        Section(title: "Arrange pages", topics: [
            toolTopic(.reorder),
            toolTopic(.deletePages),
            toolTopic(.rotate),
            toolTopic(.crop),
        ]),
        Section(title: "Compress & watermark", topics: [
            toolTopic(.compress),
            toolTopic(.watermark),
        ]),
        Section(title: "Secure & sign", topics: [
            toolTopic(.protect),
            toolTopic(.redact),
            toolTopic(.fillSign),
            toolTopic(.metadata),
        ]),
        Section(title: "Settings and more", topics: [
            Topic(id: "settings", title: "Settings", systemImage: "gearshape", article: Article(
                intro: "Open Settings with ⌘, or the gear button in any toolbar. Changes apply live across the whole app.",
                blocks: [
                    .bullets([
                        "Appearance — Theme (System, Light, Dark), Tool colors (Multicolor, Single, Monochrome), the Glass effect and Tint, the content surface, and tool preview panes.",
                        "Files — save location, what happens after exporting, output filename suffixes, and reopening your last tool on launch.",
                        "Advanced — activity-logging detail, default compression quality, redacted-page sharpness, and stripping metadata on export.",
                    ]),
                    .tip("The Glass effect (Clear, Frosted, Solid) controls how much of the desktop shows through the window and the dashboard tiles."),
                ],
                related: ["quick-actions", "welcome"]
            )),
            Topic(id: "quick-actions", title: "Quick Actions (⌘K)", systemImage: "command", article: Article(
                intro: "Press ⌘K anywhere to open the Quick Actions palette — a keyboard-first way to jump to any tool or setting.",
                blocks: [
                    .bullets([
                        "Start typing to filter tools, Settings, and the Activity Log.",
                        "Press Return to jump straight to the highlighted action.",
                        "Press ⌘K again, or Esc, to dismiss it.",
                    ]),
                ],
                related: ["the-tools", "settings"]
            )),
            Topic(id: "activity-log", title: "Activity Log", systemImage: "clock.arrow.circlepath", article: Article(
                intro: "Every operation you run is recorded in the Activity Log — handy for confirming what happened, or for troubleshooting.",
                blocks: [
                    .bullets([
                        "Open it with ⇧⌘L, the clock button in a toolbar, or Help ▸ Activity Log.",
                        "It opens in its own window, so it can sit beside your work.",
                        "Each entry notes the tool, the file, and the result; the logging detail is tunable in Settings ▸ Advanced.",
                    ]),
                ],
                related: ["privacy-safety", "quick-actions"]
            )),
            Topic(id: "privacy-safety", title: "Privacy & safety", systemImage: "checkmark.shield", article: Article(
                intro: "\(AppBrand.displayName) is built to be safe by default: nothing leaves your Mac, and your originals stay put.",
                blocks: [
                    .bullets([
                        "All processing is on-device — no PDF is ever uploaded, and passwords never leave your machine.",
                        "Tools write a new file through the save sheet; your source PDF isn't changed unless you save over it.",
                        "macOS sandboxing means a tool can only touch the files you explicitly choose or drop.",
                        "Strip metadata on export (Settings ▸ Advanced) clears author, title, and dates from files you share.",
                    ]),
                    .tip("Two actions are deliberately irreversible: Redact destroys the content it covers, and a forgotten Add-password can't be recovered. Both warn you before you save."),
                ],
                related: ["tool-redact", "tool-protect", "activity-log"]
            )),
        ]),
    ]

    // MARK: Tool topics (derived from `Tool.helpContent`)

    /// The stable topic id for a tool's article — also what `HelpPresenter.openTool` navigates to.
    static func topicID(for tool: Tool) -> String { "tool-\(tool.rawValue)" }

    /// Builds a tool's help article from its `ToolHelpContent`: overview → intro, the numbered steps
    /// and control glossary as blocks, then each tip. Keeping this derivation here means the Help book
    /// never drifts from the tool's own copy.
    static func toolTopic(_ tool: Tool) -> Topic {
        let help = tool.helpContent
        var blocks: [Block] = []
        if !help.steps.isEmpty { blocks.append(.steps(help.steps)) }
        if !help.controls.isEmpty {
            blocks.append(.controls(help.controls.map { Control(name: $0.0, detail: $0.1) }))
        }
        blocks.append(contentsOf: help.tips.map(Block.tip))
        return Topic(
            id: topicID(for: tool),
            title: tool.title,
            systemImage: tool.symbolName,
            article: Article(intro: help.overview, blocks: blocks, related: relatedIDs(for: tool))
        )
    }

    /// The "Related" chips for a tool — sibling tools a user often reaches for next, plus a safety or
    /// getting-started anchor where it helps. Every id here resolves to a real topic (`HelpBookTests`).
    static func relatedIDs(for tool: Tool) -> [String] {
        switch tool {
        case .merge: return [topicID(for: .split), topicID(for: .extract)]
        case .split: return [topicID(for: .merge), topicID(for: .extract)]
        case .extract: return [topicID(for: .split), topicID(for: .deletePages), topicID(for: .reorder)]
        case .reorder: return [topicID(for: .extract), topicID(for: .deletePages), topicID(for: .rotate)]
        case .deletePages: return [topicID(for: .extract), topicID(for: .reorder)]
        case .rotate: return [topicID(for: .reorder), topicID(for: .deletePages)]
        case .compress: return [topicID(for: .watermark), "privacy-safety"]
        case .watermark: return [topicID(for: .redact), topicID(for: .protect)]
        case .protect: return [topicID(for: .redact), topicID(for: .fillSign), "privacy-safety"]
        case .redact: return [topicID(for: .watermark), topicID(for: .protect), "privacy-safety"]
        case .fillSign: return [topicID(for: .protect), "privacy-safety"]
        case .metadata: return [topicID(for: .protect), topicID(for: .redact), "privacy-safety"]
        case .imagesToPdf: return [topicID(for: .merge), topicID(for: .compress)]
        case .crop: return [topicID(for: .rotate), topicID(for: .deletePages)]
        }
    }

    // MARK: Lookups

    /// Every topic across all sections, in sidebar order.
    static var allTopics: [Topic] { sections.flatMap(\.topics) }

    /// The topic with the given id, or nil.
    static func topic(id: String) -> Topic? { allTopics.first { $0.id == id } }

    /// The section title that owns a topic — the eyebrow above an article's heading.
    static func sectionTitle(forTopicID id: String) -> String? {
        sections.first { $0.topics.contains { $0.id == id } }?.title
    }

    /// Sections filtered to topics matching `query` (case-insensitive over title + intro + body). An
    /// empty/whitespace query returns everything; sections with no match drop out.
    static func filteredSections(matching query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.topics.filter { $0.matches(needle) }
            return hits.isEmpty ? nil : Section(title: section.title, topics: hits)
        }
    }
}

extension HelpBook.Topic {
    /// Whether this topic matches an already-lowercased search needle.
    func matches(_ needle: String) -> Bool {
        if title.lowercased().contains(needle) { return true }
        if article.intro.lowercased().contains(needle) { return true }
        return article.blocks.contains { $0.searchableText.lowercased().contains(needle) }
    }
}
