import SwiftUI

/// Right-hand preview column for tools that show page thumbnails (Merge, Compress, Rotate, Extract, Delete).
///
/// Page selection is opt-in and additive: pass `selectedPages` + `onTogglePage` (Split's custom
/// ranges, Extract) to turn each thumbnail into a click-to-toggle target with a selection check.
/// Both default to nil, so every other caller renders and behaves exactly as before.
struct SinglePDFPreviewColumn: View {
    let thumbnails: [PDFPageThumbnail]
    let isGenerating: Bool
    @Binding var thumbnailSize: CGFloat
    let accent: Color
    var previewSubtitle: String
    var emptyTitle: String
    var emptySubtitle: String
    var emptySystemImage: String = "doc.fill"

    /// 1-based page numbers currently selected. nil disables the whole selection layer (the default),
    /// so the thumbnails render as plain, non-interactive previews for tools that don't opt in.
    var selectedPages: Set<Int>? = nil
    /// Invoked with a 1-based page number when its thumbnail is clicked. Only consulted when
    /// `selectedPages` is non-nil.
    var onTogglePage: ((Int) -> Void)? = nil
    /// Optional one-line hint shown under the subtitle while selecting, explaining what a click does.
    var selectionPrompt: String? = nil

    var body: some View {
        Group {
            if !thumbnails.isEmpty || isGenerating {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center) {
                            Text("Preview")
                                .font(.title3.weight(.semibold))
                            Spacer(minLength: 8)
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.regular)
                            }
                        }
                        Text(previewSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let selectionPrompt {
                            Label(selectionPrompt, systemImage: "hand.tap")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Thumbnail size")
                                .font(.subheadline.weight(.semibold))
                            HStack(alignment: .center, spacing: 10) {
                                Text("S")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .center)
                                Slider(value: $thumbnailSize, in: 60...240)
                                    .controlSize(.regular)
                                    .disabled(isGenerating)
                                    .opacity(isGenerating ? 0.45 : 1)
                                Text("L")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .center)
                            }
                            Text("\(Int(thumbnailSize)) pt")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 4)
                        }
                        .padding(14)
                        .frame(maxWidth: 360, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Thumbnail size, \(Int(thumbnailSize)) points")
                    }
                    .padding(18)

                    Divider()
                        .opacity(0.35)

                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(thumbnails) { page in
                                pageCell(page)
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            } else {
                VStack(spacing: 16) {
                    Image(systemName: emptySystemImage)
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text(emptyTitle)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(emptySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToolPreviewPaneBackground())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page cell

    /// One thumbnail. When selection is opted into, it becomes a click-to-toggle button carrying a
    /// selection check and accent ring; otherwise it renders exactly as the plain preview always has.
    @ViewBuilder
    private func pageCell(_ page: PDFPageThumbnail) -> some View {
        if let selectedPages, let onTogglePage {
            let isSelected = selectedPages.contains(page.pageNumber)
            Button {
                onTogglePage(page.pageNumber)
            } label: {
                thumbnail(page, selectable: true, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Page \(page.pageNumber)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Toggles whether this page is included")
        } else {
            thumbnail(page, selectable: false, isSelected: false)
        }
    }

    private func thumbnail(_ page: PDFPageThumbnail, selectable: Bool, isSelected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: page.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailSize)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .overlay {
                    if selectable && isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selectable {
                        selectionBadge(isSelected: isSelected)
                            .padding(7)
                    }
                }

            Text("\(page.pageNumber)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accent)
                .clipShape(Capsule())
                .padding(6)
        }
        // Selected pages stay opaque; unselected dim slightly so the chosen set reads at a glance.
        .opacity(!selectable || isSelected ? 1 : 0.72)
    }

    /// Top-left check for a selectable thumbnail. Both states carry their own backing disc so they
    /// stay legible over any page — a white page would otherwise swallow a plain glyph.
    @ViewBuilder
    private func selectionBadge(isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, accent)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }
}
