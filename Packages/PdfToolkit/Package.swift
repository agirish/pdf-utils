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
    dependencies: [
        .package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.1.1"),
    ],
    targets: [
        .target(
            name: "PdfToolkit",
            dependencies: [
                .product(name: "PDFToolkitCore", package: "pdf-toolkit"),
            ],
            path: "Sources/PdfToolkit"
        ),
        .testTarget(
            name: "PdfToolkitTests",
            dependencies: [
                "PdfToolkit",
                .product(name: "PDFToolkitCore", package: "pdf-toolkit"),
            ],
            path: "Tests/PdfToolkitTests"
        ),
    ]
)
