// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PdfUtils",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "PdfUtils", targets: ["PdfUtils"]),
    ],
    targets: [
        .executableTarget(
            name: "PdfUtils",
            path: "Sources/PdfUtils"
        ),
    ]
)
