import SwiftUI

/// Right-hand preview column for single-file tools (Compress, Rotate), aligned with Merge PDF’s preview pane.
struct SinglePDFPreviewColumn: View {
    let thumbnails: [PDFPageThumbnail]
    let isGenerating: Bool
    @Binding var thumbnailSize: CGFloat
    let accent: Color
    var previewSubtitle: String
    var emptyTitle: String
    var emptySubtitle: String
    var emptySystemImage: String = "doc.fill"

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
                                ZStack(alignment: .bottomTrailing) {
                                    Image(nsImage: page.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: thumbnailSize)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                                    Text("\(page.pageNumber)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(accent)
                                        .clipShape(Capsule())
                                        .padding(6)
                                }
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
}
