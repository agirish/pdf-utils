import AppKit
import SwiftUI

/// macOS Settings (⌘,). Layout and liquid glass controls follow SyncCloud `Modules/Settings` + `Design`.
public struct SettingsView: View {
    public init() {}
    @AppStorage(SettingsKeys.mainWindowBackground)
    private var mainWindowBackgroundRaw: String = MainWindowBackgroundStyle.liquidGlass.rawValue

    @AppStorage(LiquidGlass.intensityKey)
    private var glassIntensity: Double = 0.65

    @AppStorage(LiquidGlass.hueKey)
    private var selectedHueRaw: String = LiquidGlassHue.purple.rawValue

    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergePreviewBackgroundRaw: String = MergePreviewBackgroundStyle.white.rawValue

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .purple
    }

    private var mainStyle: MainWindowBackgroundStyle {
        if mainWindowBackgroundRaw == "accentGradient" { return .liquidGlass }
        return MainWindowBackgroundStyle(rawValue: mainWindowBackgroundRaw) ?? .liquidGlass
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    mainBackgroundSection
                    liquidGlassSection
                    mergePreviewSection
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(0.6)

            footer
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .background(SettingsWindowResizableHook())
        .onAppear(perform: migrateLegacyDefaults)
    }

    /// Older builds stored `accentGradient`; map to liquid glass once.
    private func migrateLegacyDefaults() {
        if mainWindowBackgroundRaw == "accentGradient" {
            mainWindowBackgroundRaw = MainWindowBackgroundStyle.liquidGlass.rawValue
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Settings")
                    .font(.system(size: 26, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Text("Appearance matches the Liquid Glass pattern from SyncCloud: pick a flat mode or tune glass hue and strength.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.6)
        }
        .glassBarStyle(intensity: glassIntensity)
    }

    private var mainBackgroundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Window background")

            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $mainWindowBackgroundRaw) {
                    ForEach(MainWindowBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(mainStyle.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    private var liquidGlassSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Liquid glass")

            Text("Used when the window mode is Liquid glass. Other modes ignore these.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Accent color")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(LiquidGlassHue.allCases) { hue in
                            HueOptionView(
                                hue: hue,
                                isSelected: selectedHue == hue,
                                action: { selectedHueRaw = hue.rawValue }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
            .opacity(mainStyle == .liquidGlass ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 10) {
                Text("Glass effect")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Slider(value: $glassIntensity, in: 0.0...1.0)
                        .controlSize(.regular)
                        .disabled(mainStyle != .liquidGlass)
                    Text("\(Int(glassIntensity * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
            .opacity(mainStyle == .liquidGlass ? 1 : 0.45)
        }
    }

    private var mergePreviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Tool preview panes")

            VStack(alignment: .leading, spacing: 10) {
                Picker("Preview pane", selection: $mergePreviewBackgroundRaw) {
                    ForEach(MergePreviewBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Text(mergeStyleDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var mergeStyleDetail: String {
        (MergePreviewBackgroundStyle(rawValue: mergePreviewBackgroundRaw) ?? .white).detail
    }

    private var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes apply immediately. Close this window when you’re done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("\(AppBrand.displayName) \(version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .glassBarStyle(intensity: glassIntensity)
    }
}

// MARK: - Hue swatch (SyncCloud-style)

private struct HueOptionView: View {
    let hue: LiquidGlassHue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(hue.accentColor)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2.5)
                        )
                        .shadow(color: hue.accentColor.opacity(0.4), radius: isSelected ? 6 : 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(width: 64)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings window chrome

/// SwiftUI `Settings` often builds an `NSWindow` without `.resizable`, so the size grip does nothing until this runs.
private struct SettingsWindowResizableHook: NSViewRepresentable {
    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            applyResizeMask(window)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.applyResizeMask(window)
            }
        }

        private func applyResizeMask(_ window: NSWindow) {
            window.styleMask.insert([.resizable, .miniaturizable])
        }
    }

    func makeNSView(context: Context) -> NSView {
        AnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
