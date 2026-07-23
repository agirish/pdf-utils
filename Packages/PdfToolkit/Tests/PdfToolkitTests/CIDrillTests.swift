import Testing

// TEMPORARY — CI red/green drill (2026-07-22). Deliberately failing test that
// proves the pipeline turns main red with an actionable log. This commit is
// reverted immediately by the very next commit; if you are reading it in
// history, it was never meant to live longer than one run.
@Suite struct CIDrillTests {
    @Test func deliberateFailureForCIDrill() {
        #expect(1 == 999, "intentional CI drill failure — reverted immediately")
    }
}
