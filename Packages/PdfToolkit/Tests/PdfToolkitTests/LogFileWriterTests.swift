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

    @Test func twoWritersSharingOneFileKeepEveryAppendedLine() {
        // The app and the menu-bar Helper each own a LogFileWriter over the same `~/pdf-utils.log`.
        // Two writers on one path stand in for the two processes here: O_APPEND makes concurrent
        // appends atomic, so no line is interleaved or lost even when they write at the same time.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let appWriter = LogFileWriter(url: url)
        let helperWriter = LogFileWriter(url: url)

        let perWriter = 200
        DispatchQueue.concurrentPerform(iterations: perWriter) { i in
            appWriter.append("app-\(i)\n")
            helperWriter.append("helper-\(i)\n")
        }
        appWriter.flush()
        helperWriter.flush()

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        // Every line lands intact (no partial/spliced lines) and none are dropped.
        #expect(lines.count == perWriter * 2)
        #expect(lines.allSatisfy { $0.hasPrefix("app-") || $0.hasPrefix("helper-") })
        #expect(lines.filter { $0.hasPrefix("app-") }.count == perWriter)
        #expect(lines.filter { $0.hasPrefix("helper-") }.count == perWriter)
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
