import AppKit
import Foundation

/// What happens to a file once a tool finishes saving it. Raw values are the stored form of
/// `SettingsKeys.afterExportAction`, so treat them as stable.
public enum AfterExportAction: String, CaseIterable, Identifiable, Sendable {
    /// Save and stay put — no Finder, no opening.
    case doNothing
    /// Select the saved file(s) in Finder.
    case revealInFinder
    /// Open the saved file in the default PDF app (or the folder, for multi-file output).
    case openFile

    public var id: String { rawValue }

    /// The persisted default: reveal in Finder. It matches what Split already did before this setting
    /// existed, so turning the knob on for every tool changes nothing for that one.
    public static let defaultAction: AfterExportAction = .revealInFinder

    public static func current(_ defaults: UserDefaults = .standard) -> AfterExportAction {
        defaults.string(forKey: SettingsKeys.afterExportAction).flatMap(AfterExportAction.init(rawValue:)) ?? defaultAction
    }

    public var displayName: String {
        switch self {
        case .doNothing: return "Do nothing"
        case .revealInFinder: return "Reveal in Finder"
        case .openFile: return "Open the file"
        }
    }

    public var detail: String {
        switch self {
        case .doNothing: return "Just save. You'll find the file wherever you chose."
        case .revealInFinder: return "Select the saved file in a Finder window."
        case .openFile: return "Open the saved file in your default PDF app."
        }
    }

    /// Runs this action against the file(s) just written. `revealInFinder` selects them; `openFile`
    /// opens a single file, or reveals a multi-file batch (there's no single file to open). Safe to
    /// call with an empty array (does nothing).
    @MainActor
    public func perform(on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch self {
        case .doNothing:
            break
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .openFile:
            if urls.count == 1 {
                NSWorkspace.shared.open(urls[0])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }
}

/// Where a tool writes its output. Raw values are the stored form of `SettingsKeys.saveLocation`.
public enum SaveLocation: String, CaseIterable, Identifiable, Sendable {
    /// Show the system save dialog every time (the app's original behavior).
    case askEachTime
    /// Write next to the source file automatically, skipping the dialog.
    case besideOriginal

    public var id: String { rawValue }

    public static let defaultLocation: SaveLocation = .askEachTime

    public static func current(_ defaults: UserDefaults = .standard) -> SaveLocation {
        defaults.string(forKey: SettingsKeys.saveLocation).flatMap(SaveLocation.init(rawValue:)) ?? defaultLocation
    }

    public var displayName: String {
        switch self {
        case .askEachTime: return "Ask each time"
        case .besideOriginal: return "Save beside original"
        }
    }

    public var detail: String {
        switch self {
        case .askEachTime:
            return "Choose the destination in a save dialog for every file."
        case .besideOriginal:
            return "Skip the dialog and write into the source file's folder. A suffix keeps the original intact; a name clash is numbered, never overwritten."
        }
    }
}
