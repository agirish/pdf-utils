// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PdfToolkit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PdfToolkit", targets: ["PdfToolkit"]),
    ],
    targets: [
        .target(
            name: "PdfToolkit",
            path: "Sources/PdfToolkit"
        ),
        .testTarget(
            name: "PdfToolkitTests",
            dependencies: ["PdfToolkit"],
            path: "Tests/PdfToolkitTests",
            // The committed real-PDF corpus (see docs/testing-corpus.md). Copied
            // rather than processed: these are opaque binaries whose exact bytes
            // are the fixture, and SwiftPM's resource processing would be free to
            // rewrite them.
            resources: [.copy("Corpus")]
        ),
    ]
)
