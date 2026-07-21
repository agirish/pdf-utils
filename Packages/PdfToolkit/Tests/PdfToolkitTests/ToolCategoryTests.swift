import Testing
@testable import PdfToolkit

/// The dashboard categories carry two parallel sources of truth — `Tool.category` (membership) and
/// `ToolCategory.tools` (ordered contents) — so these pin them together: every tool lands in exactly
/// one section, and each section's ordered list agrees with the membership map. A tool that fell out
/// of every section (or into two) would silently vanish from, or double up on, the Categories layout.
@Suite struct ToolCategoryTests {

    @Test func categoriesPartitionEveryToolExactlyOnce() {
        let listed = ToolCategory.allCases.flatMap(\.tools)
        // No tool appears twice across all sections…
        #expect(Set(listed).count == listed.count)
        // …and the sections together cover the whole catalog, nothing more.
        #expect(Set(listed) == Set(Tool.allCases))
        #expect(listed.count == Tool.allCases.count)
    }

    @Test func membershipMapAgreesWithSectionContents() {
        for category in ToolCategory.allCases {
            for tool in category.tools {
                #expect(tool.category == category,
                        "\(tool) is listed under \(category) but reports \(tool.category)")
            }
        }
    }

    @Test func everyCategoryHasStableCopyAndIsNonEmpty() {
        for category in ToolCategory.allCases {
            #expect(category.id == category.rawValue)
            #expect(!category.displayName.isEmpty)
            #expect(!category.tools.isEmpty, "\(category) has no tools")
        }
    }

    @Test func sectionOrderIsTheCuratedOrder() {
        // Pins the deliberate section order and each section's lead tool, so a reshuffle is a reviewed
        // change rather than an accident of declaration order.
        #expect(ToolCategory.allCases == [.optimize, .organize, .edit, .secure])
        #expect(ToolCategory.optimize.tools.first == .compress)
        #expect(ToolCategory.organize.tools.first == .merge)
        #expect(ToolCategory.edit.tools.first == .crop)
        #expect(ToolCategory.secure.tools.first == .redact)
    }
}
