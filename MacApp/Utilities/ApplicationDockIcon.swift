import AppKit

/// SwiftPM does not run `actool`; the Dock shows the generic “exec” icon unless we set `applicationIconImage`
/// and do it early (before finish launching) so the stable already reflects the artwork.
enum ApplicationDockIcon {
    private static let nestedIconPath =
        "Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

    @MainActor
    static func apply() {
        guard let url = resolveIconURL() else { return }
        guard let image = NSImage(contentsOf: url) else { return }
        image.isTemplate = false
        NSApp.applicationIconImage = image
    }

    private static func resolveIconURL() -> URL? {
        let module = Bundle.module

        if let url = module.url(forResource: "AppDockIcon", withExtension: "png") {
            return url
        }
        if let url = module.url(
            forResource: "icon_512x512@2x",
            withExtension: "png",
            subdirectory: "Assets.xcassets/AppIcon.appiconset"
        ) {
            return url
        }

        let inModule = module.bundleURL.appendingPathComponent(nestedIconPath)
        if FileManager.default.fileExists(atPath: inModule.path) {
            return inModule
        }

        let siblingBundle = Bundle.main.bundleURL
            .appendingPathComponent("PdfUtils_PdfUtils.bundle")
            .appendingPathComponent(nestedIconPath)
        if FileManager.default.fileExists(atPath: siblingBundle.path) {
            return siblingBundle
        }

        return nil
    }
}
