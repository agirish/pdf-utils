import Testing
@testable import PdfToolkit

/// The persisted within-category tool order round-trips through a string and is *self-healing* the
/// same way ``ToolCategoryOrder`` is: whatever is stored, `resolve(_:for:)` always yields that
/// category's full membership exactly once, in canonical order for anything not pinned. That invariant
/// is what lets the stored value survive adding, moving, or removing a tool without a section dropping
/// or duplicating a tile.
@Suite struct ToolOrderTests {

    @Test func emptyStringResolvesEachCategoryToItsCuratedOrder() {
        for category in ToolCategory.allCases {
            #expect(ToolOrder.resolve("", for: category) == category.tools)
        }
        #expect(ToolOrder.isDefault(""))
    }

    @Test func roundTripsACustomOrderForOneCategory() {
        let custom: [Tool] = [.split, .merge, .rotate, .extract, .reorder, .deletePages]
        let raw = ToolOrder.replacing(.organize, with: custom, in: "")
        #expect(ToolOrder.resolve(raw, for: .organize) == custom)
        #expect(!ToolOrder.isDefault(raw))
        // Other categories are untouched by an organize-only override.
        #expect(ToolOrder.resolve(raw, for: .edit) == ToolCategory.edit.tools)
    }

    @Test func resolveAlwaysReturnsEveryMemberExactlyOnce() {
        // Junk, a duplicate, a foreign tool, and a partial list — each still resolves to the full
        // membership of the category, once each, and only that category's tools.
        let raws = [
            "",
            "organize:merge",
            "organize:merge,merge,split",
            "organize:crop,merge,bogus,split",   // crop belongs to .edit → dropped
            "organize:split,merge,extract,reorder,deletePages,rotate,extra",
        ]
        for raw in raws {
            let resolved = ToolOrder.resolve(raw, for: .organize)
            #expect(Set(resolved) == Set(ToolCategory.organize.tools), "raw=\(raw)")
            #expect(resolved.count == ToolCategory.organize.tools.count, "raw=\(raw)")
        }
    }

    @Test func unmentionedToolsAreAppendedInCanonicalOrder() {
        // Only Split is pinned; the rest follow in ToolCategory.organize.tools order behind it.
        let raw = "organize:split"
        let expected = [Tool.split] + ToolCategory.organize.tools.filter { $0 != .split }
        #expect(ToolOrder.resolve(raw, for: .organize) == expected)
    }

    @Test func replacingWithTheCanonicalOrderClearsTheSegment() {
        // Storing a category's default order shouldn't persist a segment for it.
        let raw = ToolOrder.replacing(.organize, with: ToolCategory.organize.tools, in: "organize:split,merge")
        #expect(!raw.contains("organize"))
        #expect(ToolOrder.isDefault(raw))
    }

    @Test func foreignToolsInReplacementAreIgnored() {
        // Passing a tool from another category doesn't smuggle it into this section.
        let raw = ToolOrder.replacing(.optimize, with: [.compress, .crop, .ocr], in: "")
        #expect(ToolOrder.resolve(raw, for: .optimize) == [.compress, .ocr])
        #expect(ToolOrder.resolve(raw, for: .edit).contains(.crop))
    }

    @Test func movingUpSwapsWithThePriorTool() {
        // organize default: [merge, split, extract, reorder, deletePages, rotate]; move split up.
        let raw = ToolOrder.moving(.split, .up, in: "")
        #expect(ToolOrder.resolve(raw, for: .organize).prefix(2) == [.split, .merge])
    }

    @Test func movingDownSwapsWithTheNextTool() {
        let raw = ToolOrder.moving(.merge, .down, in: "")
        #expect(ToolOrder.resolve(raw, for: .organize).prefix(2) == [.split, .merge])
    }

    @Test func movingPastAnEdgeIsANoOp() {
        #expect(ToolOrder.isDefault(ToolOrder.moving(.merge, .up, in: "")))
        #expect(ToolOrder.isDefault(ToolOrder.moving(.rotate, .down, in: "")))
    }

    @Test func multipleCategoriesCoexistInOneString() {
        var raw = ToolOrder.replacing(.organize, with: [.split, .merge, .extract, .reorder, .deletePages, .rotate], in: "")
        raw = ToolOrder.replacing(.optimize, with: [.ocr, .compress], in: raw)
        #expect(ToolOrder.resolve(raw, for: .organize).first == .split)
        #expect(ToolOrder.resolve(raw, for: .optimize) == [.ocr, .compress])
    }
}
