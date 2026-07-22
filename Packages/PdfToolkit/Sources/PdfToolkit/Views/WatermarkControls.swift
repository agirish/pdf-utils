import AppKit
import PDFKit
import SwiftUI

/// A SwiftUI `Font` for a watermark family name (empty = the bold system font), resolved through the
/// same `watermarkFont` the stamp uses so the preview and the output pick the exact same face.
func watermarkFamilyFont(_ family: String, size: CGFloat) -> Font {
    if family.isEmpty { return .system(size: size, weight: .bold) }
    return Font(PDFToolkit.watermarkFont(named: family, size: size) as CTFont)
}

/// A faithful live preview of the text/image watermark, drawn on a proportional page so Size, Angle,
/// Opacity, and the Tiled layout read against a representative sample rather than a single decorative
/// stamp. It mirrors ``PDFToolkit/drawWatermark(in:box:trimmedText:options:)``: a US-Letter reference
/// page, the mark centered or tiled across the page diagonal at its true relative size, rotated to
/// match the output (a y-down canvas negates the y-up context's angle), at the chosen opacity.
struct WatermarkPreviewCanvas: View {
    let mode: WatermarkOptions.Content
    let text: String
    let fontFamily: String
    let fontSize: CGFloat
    let color: Color
    let opacity: CGFloat
    let rotation: CGFloat
    let tiled: Bool
    let image: NSImage?
    let imageScale: CGFloat

    /// US Letter, portrait — the reference the on-page size is measured against.
    private static let referencePage = CGSize(width: 612, height: 792)

    var body: some View {
        Canvas { context, size in
            let page = Self.pageRect(in: size)
            let scale = page.width / Self.referencePage.width

            let pagePath = Path(roundedRect: page, cornerRadius: 4)
            context.fill(pagePath, with: .color(.white))
            context.stroke(pagePath, with: .color(.black.opacity(0.12)), lineWidth: 1)

            var mark = context
            mark.clip(to: pagePath)
            mark.translateBy(x: page.midX, y: page.midY)
            // The stamp rotates in a y-up context; this canvas is y-down, so negate to match the
            // visual tilt of the saved file.
            mark.rotate(by: .degrees(-rotation))
            mark.opacity = opacity

            switch mode {
            case .text:
                drawText(in: &mark, page: page, scale: scale)
            case .image:
                drawImage(in: &mark, page: page, scale: scale)
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// Fits a reference-aspect page centered in the canvas.
    private static func pageRect(in size: CGSize) -> CGRect {
        let aspect = referencePage.width / referencePage.height
        var w = size.height * aspect
        var h = size.height
        if w > size.width {
            w = size.width
            h = size.width / aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func drawText(in context: inout GraphicsContext, page: CGRect, scale: CGFloat) {
        let display = text.isEmpty ? "DRAFT" : text
        let resolved = context.resolve(
            Text(display).font(watermarkFamilyFont(fontFamily, size: max(4, fontSize * scale))).foregroundColor(color)
        )
        let textSize = resolved.measure(in: CGSize(width: 10_000, height: 10_000))
        if tiled {
            tile(page: page, cellWidth: textSize.width, cellHeight: textSize.height, scale: scale) { point in
                context.draw(resolved, at: point, anchor: .center)
            }
        } else {
            context.draw(resolved, at: .zero, anchor: .center)
        }
    }

    private func drawImage(in context: inout GraphicsContext, page: CGRect, scale: CGFloat) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let resolved = context.resolve(Image(nsImage: image))
        let fit = min(page.width * imageScale / image.size.width, page.height * imageScale / image.size.height)
        let drawSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let centered = CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2, width: drawSize.width, height: drawSize.height)
        if tiled {
            tile(page: page, cellWidth: drawSize.width, cellHeight: drawSize.height, scale: scale, spacing: 60) { point in
                context.draw(resolved, in: centered.offsetBy(dx: point.x, dy: point.y))
            }
        } else {
            context.draw(resolved, in: centered)
        }
    }

    /// Steps a grid over the page diagonal (so a rotated tiling still covers the corners), matching the
    /// stamp's `cell + spacing*scale` step. `draw` is called at each cell center, relative to the
    /// page's center (the current translation origin).
    private func tile(page: CGRect, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat, spacing: CGFloat = 100, draw: (CGPoint) -> Void) {
        let diagonal = (page.width * page.width + page.height * page.height).squareRoot()
        let stepX = max(1, cellWidth + spacing * scale)
        let stepY = max(1, cellHeight + spacing * scale)
        var y = -diagonal / 2
        while y <= diagonal / 2 {
            var x = -diagonal / 2
            while x <= diagonal / 2 {
                draw(CGPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
        }
    }
}

/// A searchable font picker that shows each family in its own typeface — the fix for the flat,
/// unsearchable menu of every installed family. "System (default)" leads; the rest filter as you type.
struct WatermarkFontPicker: View {
    /// The chosen family display name; empty means the bold system default.
    @Binding var family: String
    let families: [String]

    @State private var isPresented = false
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(family.isEmpty ? "System (default)" : family)
                    .font(watermarkFamilyFont(family, size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help("Choose the font for the text watermark")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        row(name: "System (default)", value: "", size: 13)
                        if filtered.isEmpty {
                            Text("No fonts match “\(query)”.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        ForEach(filtered, id: \.self) { fam in
                            row(name: fam, value: fam, size: 15)
                        }
                    }
                }
                .frame(width: 260, height: 320)
            }
        }
    }

    private func row(name: String, value: String, size: CGFloat) -> some View {
        Button {
            family = value
            isPresented = false
        } label: {
            HStack {
                Text(name)
                    .font(watermarkFamilyFont(value, size: size))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if family == value {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
