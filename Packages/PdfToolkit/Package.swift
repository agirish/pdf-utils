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
            path: "Sources/PdfToolkit",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
