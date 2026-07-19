import Testing
import Foundation
@testable import PdfToolkit

struct LogFileWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfutils-writer-\(UUID().uuidString).log")
    }

    @Test func appendPersistsInOrder() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = LogFileWriter(url: url)
        writer.append("hello\n")
        writer.append("world\n")
        writer.flush()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(contents == "hello\nworld\n")
    }

    @Test func clearEmptiesFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = LogFileWriter(url: url)
        writer.append("data\n")
        writer.flush()
        writer.clear()
        writer.flush()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(contents.isEmpty)
    }

    @Test func initTrimsOversizedFileToLineBoundary() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let maxSize = 400
        // Pre-write a file well over the cap, as many complete lines.
        let big = (0..<200).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try big.write(to: url, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: url).count > maxSize)

        // Constructing the writer runs the init-time trim on its queue; flush awaits it.
        let writer = LogFileWriter(url: url, maxFileSize: maxSize)
        writer.flush()

        let data = try Data(contentsOf: url)
        #expect(data.count <= maxSize)
        // The trim drops the partial first line, so the file still starts at a line boundary.
        let contents = String(data: data, encoding: .utf8) ?? ""
        #expect(contents.hasPrefix("line-"))
    }
}
