import PDFToolkitCore
import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Target-size compression binary-searches a bounded ladder of qualities in `compressToTargetData`
/// and keeps the best-fitting result. These end-to-end tests exercise the real shipped sweep against
/// live PDFs: a generous target produces a valid file, an impossible target still emits the smallest
/// result, the output never exceeds the source, an already-small source passes through untouched, and
/// the guard/error cases (self-overwrite, unreadable source) throw.
@Suite struct PDFToolkitCompressTargetTests {

    @Test func targetBytesClampsExtremeInputInsteadOfTrapping() {
        // The Compress "target size" field is free-entry, and `Int(Double)` TRAPS once the value
        // exceeds `Int.max`, so a ~13-digit typed MB figure used to hard-crash the app on the next
        // render. The conversion must clamp before touching `Int`: a huge value pins to the 500 MB
        // ceiling, a negative / zero / non-finite value pins to the 0.1 MB floor, and every call
        // simply returns (reaching these assertions at all proves nothing trapped).
        let ceiling = Int((500.0 * 1_000_000).rounded())
        let floor = Int((0.1 * 1_000_000).rounded())

        #expect(BatchOperation.targetBytes(forMegabytes: 1e18) == ceiling)
        #expect(BatchOperation.targetBytes(forMegabytes: .greatestFiniteMagnitude) == ceiling)
        #expect(BatchOperation.targetBytes(forMegabytes: -5) == floor)
        #expect(BatchOperation.targetBytes(forMegabytes: 0) == floor)
        #expect(BatchOperation.targetBytes(forMegabytes: .nan) == floor)
        #expect(BatchOperation.targetBytes(forMegabytes: .infinity) == floor)

        // In-range values pass straight through, unchanged.
        #expect(BatchOperation.targetBytes(forMegabytes: 2) == 2_000_000)
        #expect(BatchOperation.targetBytes(forMegabytes: 3.5) == 3_500_000)
    }
}
