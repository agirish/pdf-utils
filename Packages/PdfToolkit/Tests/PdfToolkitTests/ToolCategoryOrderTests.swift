import Testing
@testable import PdfToolkit

/// The persisted Categories-view order round-trips through a string and, crucially, is *self-healing*:
/// whatever is stored, `resolve` always yields the full set of categories exactly once. That invariant
/// is what lets the stored value survive adding, removing, or renaming a category without the dashboard
/// dropping or duplicating a section.
@Suite struct ToolCategoryOrderTests {

    @Test func emptyStringResolvesToTheDefaultOrder() {
        #expect(ToolCategoryOrder.resolve("") == ToolCategory.allCases)
        #expect(ToolCategoryOrder.isDefault(ToolCategoryOrder.resolve("")))
    }

    @Test func roundTripsACustomOrder() {
        let custom: [ToolCategory] = [.edit, .secure, .optimize, .organize]
        let serialized = ToolCategoryOrder.serialize(custom)
        #expect(ToolCategoryOrder.resolve(serialized) == custom)
        #expect(!ToolCategoryOrder.isDefault(custom))
    }

    @Test func resolveAlwaysReturnsEveryCategoryExactlyOnce() {
        // Junk, a duplicate, and a partial list — each must still resolve to the complete set, no dupes.
        for raw in ["", "edit", "edit,edit,secure", "bogus,edit,,secure", "edit,secure,optimize,organize,extra"] {
            let resolved = ToolCategoryOrder.resolve(raw)
            #expect(Set(resolved) == Set(ToolCategory.allCases), "raw=\(raw)")
            #expect(resolved.count == ToolCategory.allCases.count, "raw=\(raw)")
        }
    }

    @Test func missingCategoriesAreAppendedInCanonicalOrder() {
        // Only Edit is named; the rest follow in allCases order, right after it.
        #expect(ToolCategoryOrder.resolve("edit") == [.edit, .optimize, .organize, .secure])
    }

    @Test func movingUpSwapsWithThePriorSection() {
        // Default is [optimize, organize, edit, secure]; move edit up → it trades with organize.
        let moved = ToolCategoryOrder.moving(.edit, .up, in: ToolCategory.allCases)
        #expect(moved == [.optimize, .edit, .organize, .secure])
    }

    @Test func movingDownSwapsWithTheNextSection() {
        let moved = ToolCategoryOrder.moving(.optimize, .down, in: ToolCategory.allCases)
        #expect(moved == [.organize, .optimize, .edit, .secure])
    }

    @Test func movingPastAnEdgeIsANoOp() {
        #expect(ToolCategoryOrder.moving(.optimize, .up, in: ToolCategory.allCases) == ToolCategory.allCases)
        #expect(ToolCategoryOrder.moving(.secure, .down, in: ToolCategory.allCases) == ToolCategory.allCases)
    }
}
