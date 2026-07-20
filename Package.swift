// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PdfUtils",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "PdfUtils", targets: ["PdfUtils"]),
        .executable(name: "PdfUtilsFinder", targets: ["PdfUtilsFinder"]),
        .executable(name: "PdfUtilsHelper", targets: ["PdfUtilsHelper"]),
    ],
    dependencies: [
        .package(path: "Packages/PdfToolkit"),
    ],
    targets: [
        .executableTarget(
            name: "PdfUtils",
            dependencies: [
                .product(name: "PdfToolkit", package: "PdfToolkit"),
            ],
            path: "MacApp",
            exclude: ["Info.plist"],
            resources: [
                .process("Assets.xcassets"),
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
        // Finder Sync app extension. SwiftPM has no `.appex` product type, so this is a
        // plain executable target whose entry point is redirected to `_NSExtensionMain`
        // (the app-extension runtime shim in Foundation) via the linker `-e` flag. The
        // build script then assembles the binary into `PDF Utils.app/Contents/PlugIns/
        // PdfUtilsFinder.appex` with its own Info.plist + sandbox entitlements.
        .executableTarget(
            name: "PdfUtilsFinder",
            dependencies: [
                .product(name: "PdfToolkit", package: "PdfToolkit"),
            ],
            path: "FinderExtension",
            exclude: ["Info.plist", "PdfUtilsFinder.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                ], .when(platforms: [.macOS])),
            ]
        ),
        // Resident menu-bar helper (LSUIElement agent). A normal executable — unlike the
        // extension it uses the standard entry point. Runs unsandboxed so it has real file
        // access, and does the PDF work the sandboxed extension can't. Assembled into
        // `PDF Utils.app/Contents/Library/LoginItems/PdfUtilsHelper.app`.
        .executableTarget(
            name: "PdfUtilsHelper",
            dependencies: [
                .product(name: "PdfToolkit", package: "PdfToolkit"),
            ],
            path: "Helper",
            exclude: ["Info.plist"]
        ),
    ]
)
