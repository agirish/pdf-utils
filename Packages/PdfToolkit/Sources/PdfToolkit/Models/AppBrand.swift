import Foundation

/// User-facing application name (window title, menu bar, alerts, Dock when Info.plist keys are present).
public enum AppBrand {
    public static var displayName: String {
        if let s = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String, !s.isEmpty {
            return s
        }
        if let s = Bundle.main.infoDictionary?["CFBundleName"] as? String, !s.isEmpty {
            return s
        }
        return "PDF Utils"
    }
}
