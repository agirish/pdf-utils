import Testing
@testable import PdfToolkit

/// Pins the ⌘K palette's ranking (`rankedMatches`) — the pure core behind the command palette. The
/// tiers it must honor: prefix beats substring beats subsequence, any title match beats a
/// subtitle-only match, matching is case-insensitive, ties keep catalog order, and an empty query
/// returns everything unchanged. Also fixes the shape of the shipped `QuickAction.catalog`.
@Suite struct QuickActionSearchTests {

    /// A ranking fixture — only `title`/`subtitle` matter to `rankedMatches`, so `kind` is arbitrary.
    private func action(_ id: String, _ title: String, _ subtitle: String = "") -> QuickAction {
        QuickAction(id: id, title: title, subtitle: subtitle, kind: .activityLog)
    }

    // MARK: - Empty query

    @Test func emptyQueryReturnsEveryActionInOrder() {
        let actions = [action("a", "Alpha"), action("b", "Beta"), action("c", "Gamma")]
        #expect(rankedMatches(query: "", in: actions) == actions)
        // Whitespace-only is treated as empty, not as a literal space to match.
        #expect(rankedMatches(query: "   ", in: actions) == actions)
    }

    // MARK: - Tiers

    @Test func titlePrefixOutranksTitleSubstring() {
        let prefix = action("1", "Compress")      // "com" is a prefix
        let substring = action("2", "Welcome")    // "com" is a substring, not a prefix
        // Fed in the losing order to prove it's the score, not the input order, that decides.
        #expect(rankedMatches(query: "com", in: [substring, prefix]) == [prefix, substring])
    }

    @Test func substringOutranksSubsequence() {
        let substring = action("1", "Trace")      // contains "ace"
        let subsequence = action("2", "Advance")  // a…c…e in order, but not contiguous
        #expect(rankedMatches(query: "ace", in: [subsequence, substring]) == [substring, subsequence])
    }

    @Test func titleMatchOutranksSubtitleOnlyMatch() {
        let titleMatch = action("1", "Merge PDF", "combine files")
        let subtitleMatch = action("2", "Split PDF", "merge groups into files")
        #expect(rankedMatches(query: "merge", in: [subtitleMatch, titleMatch]) == [titleMatch, subtitleMatch])
    }

    // MARK: - Subsequence matching

    @Test func matchesNonContiguousSubsequence() {
        // "cmp" is c…m…p within "Compress" — a subsequence, not a substring.
        let compress = action("1", "Compress PDF")
        let rotate = action("2", "Rotate PDF")
        // The subsequence match is kept; the non-match is dropped entirely.
        #expect(rankedMatches(query: "cmp", in: [compress, rotate]) == [compress])
    }

    @Test func nonMatchesAreExcluded() {
        let actions = [action("1", "Merge", "combine"), action("2", "Rotate", "turn pages")]
        #expect(rankedMatches(query: "zzzz", in: actions).isEmpty)
    }

    // MARK: - Case & stability

    @Test func matchingIsCaseInsensitive() {
        let compress = action("1", "Compress PDF", "Shrink file size")
        #expect(rankedMatches(query: "COMPRESS", in: [compress]) == [compress])
        #expect(rankedMatches(query: "compress", in: [compress]) == [compress])
    }

    @Test func equalScoresKeepInputOrder() {
        // Identical copy → identical score, so the tie-break must preserve the given order both ways.
        let first = action("1", "Merge")
        let second = action("2", "Merge")
        #expect(rankedMatches(query: "mer", in: [first, second]) == [first, second])
        #expect(rankedMatches(query: "mer", in: [second, first]) == [second, first])
    }

    // MARK: - Shipped catalog

    @Test func catalogCoversEveryToolAndAppAction() {
        let catalog = QuickAction.catalog
        for tool in Tool.allCases {
            #expect(catalog.contains { $0.kind == .tool(tool) }, "missing tool action for \(tool)")
        }
        #expect(catalog.contains { $0.kind == .settings(nil) })
        #expect(catalog.contains { $0.kind == .settings(.files) })
        #expect(catalog.contains { $0.kind == .settings(.appearance) })
        #expect(catalog.contains { $0.kind == .settings(.advanced) })
        #expect(catalog.contains { $0.kind == .activityLog })
    }

    @Test func catalogIdsAreUnique() {
        // Duplicate ids would collide as ForEach identities in the palette list.
        let ids = QuickAction.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func emptyQueryOverCatalogReturnsItUnchanged() {
        #expect(rankedMatches(query: "", in: QuickAction.catalog) == QuickAction.catalog)
    }

    @Test func searchingCatalogFindsAToolByName() {
        let results = rankedMatches(query: "watermark", in: QuickAction.catalog)
        #expect(results.first?.kind == .tool(.watermark))
    }

    // MARK: - Dashboard search reuse (`rankedToolMatches`)

    @Test func toolCatalogIsEveryToolAndNothingElse() {
        // The dashboard searches tools only — no Settings/Activity Log entries leak in.
        let tools = QuickAction.toolCatalog.compactMap { action -> Tool? in
            if case let .tool(tool) = action.kind { return tool }
            return nil
        }
        #expect(tools == Tool.allCases)
        #expect(QuickAction.toolCatalog.count == Tool.allCases.count)
    }

    @Test func emptyQueryReturnsEveryToolInCatalogOrder() {
        #expect(rankedToolMatches(query: "") == Tool.allCases)
        #expect(rankedToolMatches(query: "   ") == Tool.allCases)
    }

    @Test func dashboardSearchRanksLikeThePalette() {
        // Same fuzzy tiers the ⌘K palette uses: a title prefix wins, and non-matches drop out.
        #expect(rankedToolMatches(query: "watermark").first == .watermark)
        // "cmp" is c…m…p in "Compress PDF" — a subsequence match, exactly as in the palette.
        #expect(rankedToolMatches(query: "cmp").contains(.compress))
        // Matches the subtitle too ("Encrypt a PDF, or remove its password" → Password Protect).
        #expect(rankedToolMatches(query: "password").contains(.protect))
        #expect(rankedToolMatches(query: "zzzz").isEmpty)
    }
}
