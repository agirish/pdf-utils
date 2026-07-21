import Testing
@testable import PdfToolkit

/// Pinned tools are a *subset* of the catalog (default empty), not a permutation, so these pin the two
/// things that matters: the pinned order round-trips through a string, and `resolve` is forgiving of
/// junk/duplicates/removed tools so the stored value can never desync from the ``Tool`` enum.
@Suite struct PinnedToolsTests {

    @Test func emptyStringResolvesToNothingPinned() {
        #expect(PinnedTools.resolve("").isEmpty)
    }

    @Test func roundTripsPinnedOrder() {
        let pins: [Tool] = [.merge, .compress, .redact]
        let raw = PinnedTools.serialize(pins)
        #expect(PinnedTools.resolve(raw) == pins)
    }

    @Test func resolveDropsUnknownAndDuplicateTokens() {
        #expect(PinnedTools.resolve("merge,bogus,,merge,compress") == [.merge, .compress])
    }

    @Test func togglingPinsToTheEndThenUnpins() {
        var raw = ""
        raw = PinnedTools.toggling(.merge, in: raw)
        raw = PinnedTools.toggling(.compress, in: raw)
        #expect(PinnedTools.resolve(raw) == [.merge, .compress])
        #expect(PinnedTools.contains(.merge, in: raw))

        raw = PinnedTools.toggling(.merge, in: raw)
        #expect(PinnedTools.resolve(raw) == [.compress])
        #expect(!PinnedTools.contains(.merge, in: raw))
    }

    @Test func movingReordersWithinThePinnedShelf() {
        let raw = PinnedTools.serialize([.merge, .compress, .redact])
        #expect(PinnedTools.resolve(PinnedTools.moving(.compress, .up, in: raw)) == [.compress, .merge, .redact])
        #expect(PinnedTools.resolve(PinnedTools.moving(.compress, .down, in: raw)) == [.merge, .redact, .compress])
    }

    @Test func movingAnUnpinnedToolOrPastAnEdgeIsANoOp() {
        let raw = PinnedTools.serialize([.merge, .compress])
        #expect(PinnedTools.moving(.redact, .up, in: raw) == raw)   // not pinned
        #expect(PinnedTools.moving(.merge, .up, in: raw) == raw)    // already first
        #expect(PinnedTools.moving(.compress, .down, in: raw) == raw) // already last
    }
}
