import Foundation
import SwiftUI

extension String {
    /// Basename for SwiftUI `fileExporter` `defaultFilename` (strips the last path extension).
    var exportFilenameStem: String {
        (self as NSString).deletingPathExtension
    }
}

struct ToolFormContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    func formCard() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.6), lineWidth: 1)
            }
    }
}

struct RunActionButton: View {
    let title: String
    var busy: Bool = false
    /// When false, the button is disabled (e.g. no inputs yet).
    var canRun: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || !canRun)
    }
}
