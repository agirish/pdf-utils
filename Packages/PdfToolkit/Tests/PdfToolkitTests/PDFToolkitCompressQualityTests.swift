import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Unit coverage for the Compress tool's quality-preset logic and its live projected-size estimates.
/// The strength-card bucketing and the before/after reduction math are pure and tested directly; the
/// cross-file estimate guard is extracted onto the view as `shouldStoreEstimate`, so the race it fixes
/// is exercisable without driving SwiftUI; and the "distinct qualities → distinct sizes" claim the
/// cards rest on is pinned end-to-end against a real Letter fixture.
@Suite struct PDFToolkitCompressQualityTests {

    // MARK: - Strength bucket boundaries

    @Test func selectedIDBucketsAroundTheStrongBalancedThreshold() {
        // Everything below 0.45 is Strong; 0.45 itself crosses into Balanced (half-open `..<0.45`).
        #expect(CompressionStrength.selectedID(for: 0.0) == "strong")
        #expect(CompressionStrength.selectedID(for: 0.2) == "strong")
        #expect(CompressionStrength.selectedID(for: 0.449) == "strong")
        #expect(CompressionStrength.selectedID(for: 0.45) == "balanced")
    }

    @Test func selectedIDBucketsAroundTheBalancedBasicThreshold() {
        // [0.45, 0.75) is Balanced; 0.75 itself crosses into Basic. The default 0.72 stays Balanced,
        // which the disclosed slider and the Settings default both rely on.
        #expect(CompressionStrength.selectedID(for: 0.45) == "balanced")
        #expect(CompressionStrength.selectedID(for: 0.72) == "balanced")
        #expect(CompressionStrength.selectedID(for: 0.749) == "balanced")
        #expect(CompressionStrength.selectedID(for: 0.75) == "basic")
        #expect(CompressionStrength.selectedID(for: 1.0) == "basic")
    }

    @Test func eachCardsOwnQualityLightsThatCard() {
        // Every preset's representative quality must fall inside its own bucket, or tapping the card
        // would seed a quality that highlights a *different* card.
        for strength in CompressionStrength.all {
            #expect(CompressionStrength.selectedID(for: strength.quality) == strength.id)
        }
    }

    // MARK: - Reduction math

    private func result(_ input: Int64, _ output: Int64) -> CompressionResult {
        CompressionResult(inputBytes: input, outputBytes: output, url: URL(fileURLWithPath: "/tmp/out.pdf"))
    }

    @Test func reductionIsZeroForAZeroByteInput() {
        // A 0-byte input must not divide by zero — the readout reads 0%, not NaN or a crash.
        let r = result(0, 0)
        #expect(r.reductionFraction == 0)
        #expect(r.reductionPercent == 0)
    }

    @Test func reductionClampsToZeroWhenTheOutputGrew() {
        // Rasterizing a lean PDF can inflate it; a non-shrinking result reads as 0%, never negative.
        let r = result(1_000, 1_500)
        #expect(r.reductionFraction == 0)
        #expect(r.reductionPercent == 0)
    }

    @Test func reductionReportsTheShrinkFraction() {
        // 1000 → 250 is a clean 75% reduction.
        let r = result(1_000, 250)
        #expect(r.reductionFraction == 0.75)
        #expect(r.reductionPercent == 75)
    }

    @Test func reductionPercentRoundsToNearestWholePercent() {
        // 1000 → 667 is 33.3% → rounds to 33.
        #expect(result(1_000, 667).reductionPercent == 33)
        // 1000 → 665 is 33.5% → rounds to 34.
        #expect(result(1_000, 665).reductionPercent == 34)
    }

    // MARK: - Cross-file estimate guard

    @Test func storesAnEstimateOnlyForTheStillSelectedFile() {
        // A size computed for file X must land only if the caches still belong to X and the task wasn't
        // superseded — the guard that closes the stale-cross-file-estimate race.
        #expect(CompressToolView.shouldStoreEstimate(computedPath: "/X.pdf", currentPath: "/X.pdf", isCancelled: false))
        // Selection moved to Y (its caches were reset): X's result must be dropped, not written into Y.
        #expect(!CompressToolView.shouldStoreEstimate(computedPath: "/X.pdf", currentPath: "/Y.pdf", isCancelled: false))
        // No file selected any more.
        #expect(!CompressToolView.shouldStoreEstimate(computedPath: "/X.pdf", currentPath: nil, isCancelled: false))
        // Same file, but the task was superseded (e.g. quality changed): drop it so a stale value can't land.
        #expect(!CompressToolView.shouldStoreEstimate(computedPath: "/X.pdf", currentPath: "/X.pdf", isCancelled: true))
    }

    // MARK: - Distinct sizes per quality (the strength cards' core claim)

    @Test func distinctQualitiesProduceDistinctMonotoneSizes() throws {
        // The three cards advertise *different* projected sizes; that rests on `compressData` returning
        // a strictly larger file at higher quality (on a standard page the JPEG-encoding factor is the
        // active size lever). Pinned on a real multi-page Letter fixture at the exact card qualities.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 6, to: src)

        let basic = try PDFToolkit.compressData(inputURL: src, quality: 0.85).count
        let balanced = try PDFToolkit.compressData(inputURL: src, quality: 0.6).count
        let strong = try PDFToolkit.compressData(inputURL: src, quality: 0.35).count

        #expect(basic > balanced)
        #expect(balanced > strong)
        // And all three are genuinely distinct — no two cards would show the same number.
        #expect(Set([basic, balanced, strong]).count == 3)
    }
}
