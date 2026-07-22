import Foundation

/// The content behind Help ▸ PDF Utils Help (⌘?). Pure data — a handful of sections, each a list of
/// topics, each topic a short article of typed blocks — kept UI-free so `HelpBookTests` can pin the
/// shape (unique ids, resolvable cross-links, no empty copy) without a view.
///
/// Every tool's article is *derived* from its `Tool.helpContent`, so the words a user reads in the
/// Help book and the words on the tool's own screen are one and the same source — update
/// `ToolHelpContent` and both move together. The sidebar sections mirror the dashboard's categories
/// (`ToolCategory`). The other topics (getting started, working with several files, Finder shortcuts,
/// settings, safety) are authored here directly. Deliberately no PDFKit dependency: this is words
/// about the app, not the app's logic.
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
                        "Pick a tool from the dashboard — browse the categories or search by name.",
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
                        "Click Choose PDF… (or Add PDFs… once a file is loaded) to pick files with the system open panel.",
                        "Or drag one or more PDFs from Finder onto the tool's drop area.",
                        "macOS grants access to exactly the files you pick, so the tools stay sandboxed.",
                        "Compress, Rotate, Watermark, and Password Protect take several PDFs at once — see Working with several files.",
                    ]),
                    .tip("If a tool says it can't access a file, choose it again with Choose PDF… or Add PDFs… so macOS can re-grant access."),
                ],
                related: ["several-files", "the-tools", "welcome"]
            )),
            Topic(id: "several-files", title: "Working with several files", systemImage: "doc.on.doc", article: Article(
                intro: "Compress, Rotate, Watermark, and Password Protect can run across a whole set of PDFs at once. Add more than one file and the tool switches from a single save to a batch queue.",
                blocks: [
                    .steps([
                        "Add more than one PDF — drag several in, or use Add PDFs…. With two or more files, the action button becomes Run on N files.",
                        "Set the tool's options once; they apply to every file in the queue.",
                        "Click Run on N files to process them all. Cancel stops a run in progress.",
                    ]),
                    .bullets([
                        "The queue shows each file's status: Waiting, Working…, a saved-size pill when it's done, or Failed with a reason.",
                        "Results follow your Save location (Settings ▸ Files): saved beside each original, or written into one folder you pick.",
                        "Show in Finder reveals the finished files once the run completes.",
                    ]),
                    .tip("Each finished file also lands in the Activity Log, so you can keep it open to watch a long batch."),
                ],
                related: ["tool-compress", "tool-rotate", "tool-watermark", "tool-protect"]
            )),
            Topic(id: "the-tools", title: "The tools at a glance", systemImage: "square.grid.2x2", article: Article(
                intro: "Every tool lives on the dashboard, grouped into four categories by what you're trying to do.",
                blocks: [
                    .bullets([
                        "Optimize — Compress shrinks a file for sharing; OCR PDF makes scanned pages searchable and selectable.",
                        "Organize pages — Merge stacks PDFs into one; Split and Extract pull files or pages out; Reorder, Delete Pages, and Rotate rework the pages of a single PDF.",
                        "Edit & annotate — Crop trims margins; Watermark stamps text or a logo; Fill & Sign adds text and a signature; Images to PDF turns pictures into a document.",
                        "Secure & clean — Redact removes content for good; Password Protect encrypts or unlocks; Clean Metadata strips hidden document info.",
                    ]),
                    .paragraph("Make the dashboard yours: search by name, pin favorites to the top, drag tools or whole sections into the order you like, or switch the layout between Categories, Grid, and List (Settings ▸ Appearance ▸ Dashboard layout)."),
                    .tip("Press ⌘K anywhere to jump straight to a tool without returning to the dashboard."),
                ],
                related: ["tool-compress", "tool-merge", "several-files", "settings"]
            )),
        ]),
        Section(title: "Optimize", topics: [
            toolTopic(.compress),
            toolTopic(.ocr),
        ]),
        Section(title: "Organize pages", topics: [
            toolTopic(.merge),
            toolTopic(.split),
            toolTopic(.extract),
            toolTopic(.reorder),
            toolTopic(.deletePages),
            toolTopic(.rotate),
        ]),
        Section(title: "Edit & annotate", topics: [
            toolTopic(.crop),
            toolTopic(.watermark),
            toolTopic(.fillSign),
            toolTopic(.imagesToPdf),
        ]),
        Section(title: "Secure & clean", topics: [
            toolTopic(.redact),
            toolTopic(.protect),
            toolTopic(.metadata),
        ]),
        Section(title: "Settings and more", topics: [
            Topic(id: "settings", title: "Settings", systemImage: "gearshape", article: Article(
                intro: "Open Settings with ⌘, or the gear button in any toolbar. Search across every setting, and changes apply live throughout the app.",
                blocks: [
                    .bullets([
                        "Files — save location, what happens after exporting, output filename suffixes, and reopening your last tool on launch.",
                        "Appearance — Theme (System, Light, Dark), the Dashboard layout (Categories, Grid, List), the Accent color, Tool colors (Multicolor, Single, Monochrome), the Glass effect and Tint, the content surface, and tool preview panes.",
                        "Advanced — activity-logging detail, default compression quality, redacted-page sharpness, stripping metadata on export, a Reset section with Reset order, Clear pinned tools, and Reset all settings, and the app's version.",
                    ]),
                    .tip("The Glass effect (Clear, Frosted, Solid) controls how much of the desktop shows through the window and the dashboard tiles."),
                ],
                related: ["quick-actions", "the-tools", "welcome"]
            )),
            Topic(id: "quick-actions", title: "Quick Actions (⌘K)", systemImage: "command", article: Article(
                intro: "Press ⌘K anywhere to open the Quick Actions palette — a keyboard-first way to jump to any tool or setting.",
                blocks: [
                    .bullets([
                        "Start typing to filter every tool, the Settings tabs, and the Activity Log.",
                        "Use ↑ / ↓ to move the highlight, and Return to jump straight to it.",
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
                        "New entries appear live as each operation finishes — including Finder right-click actions handled in the background — so you can keep it open and watch.",
                        "Filter by level (All, Info, Warnings, Errors) or search the messages; each entry notes the tool, the file, and the result, and you can reveal or open the file it produced.",
                        "Copy or Clear the shown entries, open the full log file, or load older history from earlier sessions. The logging detail is tunable in Settings ▸ Advanced.",
                    ]),
                ],
                related: ["finder-integration", "privacy-safety", "quick-actions"]
            )),
            Topic(id: "finder-integration", title: "Right-click in Finder", systemImage: "contextualmenu.and.cursorarrow", article: Article(
                intro: "Right-click a PDF (or several) in Finder to run common tools without opening the app. The work happens in the background and the result appears right next to the original.",
                blocks: [
                    .bullets([
                        "Compress PDF — shrink one or several selected PDFs.",
                        "Remove Password… — write an unlocked copy (you'll be asked for the password).",
                        "Rotate PDF — Rotate Right 90°, Rotate Left 90°, or Rotate 180°.",
                        "Extract Pages… — pull pages from a single PDF.",
                        "Merge PDFs — combine two or more selected PDFs into one.",
                    ]),
                    .paragraph("A small \(AppBrand.displayName) helper lives in the menu bar and does the actual work, then reveals the finished file in Finder. Every run is recorded in the Activity Log, so you can see what happened even though the main window never opened."),
                    .steps([
                        "Turn on the \(AppBrand.displayName) extension in System Settings ▸ Login Items & Extensions, under Finder extensions.",
                        "Use the helper's menu-bar icon to Open \(AppBrand.displayName) or toggle Start at Login so the shortcuts are always ready.",
                    ]),
                    .tip("These are the same on-device tools, just reached from Finder — nothing about a right-click action leaves your Mac."),
                ],
                related: ["activity-log", "several-files", "privacy-safety"]
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
        case .rotate: return [topicID(for: .reorder), topicID(for: .deletePages), "several-files"]
        case .compress: return [topicID(for: .watermark), "several-files", "privacy-safety"]
        case .watermark: return [topicID(for: .redact), topicID(for: .protect), "several-files"]
        case .protect: return [topicID(for: .redact), topicID(for: .fillSign), "several-files", "privacy-safety"]
        case .redact: return [topicID(for: .watermark), topicID(for: .protect), "privacy-safety"]
        case .fillSign: return [topicID(for: .protect), "privacy-safety"]
        case .metadata: return [topicID(for: .protect), topicID(for: .redact), "privacy-safety"]
        case .imagesToPdf: return [topicID(for: .ocr), topicID(for: .merge), topicID(for: .compress)]
        case .crop: return [topicID(for: .rotate), topicID(for: .deletePages)]
        case .ocr: return [topicID(for: .imagesToPdf), topicID(for: .compress), "privacy-safety"]
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
