import Testing
import AppKit
@testable import PdfToolkit

/// Pins the Tool catalog's shape: every tool has complete, unique presentation copy, its SF Symbol
/// resolves (a typo would render a blank dashboard tile), and its help content is fully populated.
/// The CONTENT is a hand-maintained mirror of the app — update a tool and this test together.
@Suite struct ToolTests {

    @Test func catalogListsEveryTool() {
        // A fixed roster so adding/removing a tool is a deliberate, reviewed change.
        #expect(Set(Tool.allCases) == Set<Tool>([
            .compress, .rotate, .merge, .split, .extract,
            .reorder, .deletePages, .watermark, .redact, .fillSign, .protect,
            .metadata, .imagesToPdf, .crop,
        ]))
        #expect(Tool.allCases.count == 14)
    }

    @Test func idEqualsRawValueAndIsUnique() {
        #expect(Tool.allCases.allSatisfy { $0.id == $0.rawValue })
        let ids = Tool.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyToolHasCompleteAndUniqueCopy() {
        for tool in Tool.allCases {
            #expect(!tool.title.isEmpty)
            #expect(!tool.subtitle.isEmpty)
            #expect(!tool.headerDescription.isEmpty)
        }
        // Titles are the primary label; two tools sharing one would be indistinguishable on the grid.
        let titles = Tool.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test func everyToolSymbolResolvesInSFSymbols() {
        // A misspelled symbol name silently renders as an empty image at runtime.
        for tool in Tool.allCases {
            #expect(!tool.symbolName.isEmpty)
            #expect(NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(tool.symbolName) for \(tool)")
        }
    }

    @Test func everyToolHasFullyPopulatedHelpContent() {
        for tool in Tool.allCases {
            let help = tool.helpContent
            #expect(!help.overview.isEmpty, "\(tool) overview")
            #expect(!help.steps.isEmpty, "\(tool) steps")
            #expect(help.steps.allSatisfy { !$0.isEmpty }, "\(tool) has a blank step")
            #expect(!help.controls.isEmpty, "\(tool) controls")
            #expect(help.controls.allSatisfy { !$0.0.isEmpty && !$0.1.isEmpty }, "\(tool) has an incomplete control")
            #expect(!help.tips.isEmpty, "\(tool) tips")
            #expect(help.tips.allSatisfy { !$0.isEmpty }, "\(tool) has a blank tip")
        }
    }
}
