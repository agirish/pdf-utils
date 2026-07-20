import SwiftUI

/// In-content hero for each tool: icon, title, a short explanation, and a Chrome-style privacy chip.
/// The chip mirrors a browser's site-security control — a compact lock pill in the header's top-right
/// that opens a popover explaining that every tool runs locally and no file leaves the Mac.
struct ToolScreenHeader: View {
    let tool: Tool
    @State private var showPrivacy = false
    @State private var chipHovered = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.toolAccent) private var accent
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // The icon plate echoes the dashboard tile's gradient plate (radius 16, accent gradient,
            // accent hairline) so opening a tool reads as that tile expanding, not a flatter chip.
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: dark
                                ? [accent.opacity(0.55), accent.opacity(0.24)]
                                : [accent.opacity(0.28), accent.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(accent.opacity(dark ? 0.55 : 0.22), lineWidth: 1)
                    }
                Image(systemName: tool.symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(tool.title)
                    .font(.title2.weight(.semibold))
                Text(tool.headerDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Combine only the title + description; the chip stays a separate, reachable button.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tool.title). \(tool.headerDescription)")

            privacyChip
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Privacy chip (browser-style site-security control)

    private var privacyChip: some View {
        Button {
            showPrivacy.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                Text("On-device")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(chipHovered ? 0.10 : 0.06)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { chipHovered = $0 }
        .help("How \(AppBrand.displayName) handles your files")
        .accessibilityLabel("Privacy and security details")
        .popover(isPresented: $showPrivacy) {
            privacyPopover
        }
    }

    private var privacyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            // Full-bleed accent rule, echoing a browser security panel's colored divider.
            Rectangle()
                .fill(Color.green)
                .frame(height: 2)
            VStack(alignment: .leading, spacing: 16) {
                privacyRow(
                    icon: "lock.fill",
                    title: "Everything stays on your Mac",
                    detail: "Your PDFs are opened, edited, and saved right here. Nothing is uploaded — no file ever leaves your machine."
                )
                privacyRow(
                    icon: "checkmark.seal.fill",
                    title: "Works completely offline",
                    detail: "No account, no network, and no servers — every tool runs locally on this Mac."
                )
            }
            .padding(16)
        }
        .frame(width: 320)
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
