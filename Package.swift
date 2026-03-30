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
            path: "MacApp",
            exclude: ["Info.plist"],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "MacApp/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ]
)
