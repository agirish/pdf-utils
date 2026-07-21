import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
