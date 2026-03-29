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
            path: "Sources/PdfUtils",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Metadata/AppInfo.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ]
)
