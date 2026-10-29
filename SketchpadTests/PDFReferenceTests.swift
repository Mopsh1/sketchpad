import Foundation
import Testing
@testable import Sketchpad

struct PDFReferenceTests {
    /// A new folder holding one file; the caller removes the folder.
    private func makeFile() throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFReferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)
        return (folder, file)
    }

    /// Temporary paths reach the same file through /var and /private/var.
    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    @Test func findsTheFileAfterItIsRenamed() throws {
        let (folder, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = PDFReference.make(for: file, title: "Paper")
        #expect(reference.bookmark != nil)

        let renamed = folder.appendingPathComponent("renamed.pdf")
        try FileManager.default.moveItem(at: file, to: renamed)
        #expect(samePath(reference.resolve(), renamed))
    }

    @Test func fallsBackToThePathWhenTheBookmarkIsUnusable() throws {
        let (folder, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        var reference = PDFReference.make(for: file, title: "Paper")
        reference.bookmark = Data("not a bookmark".utf8).base64EncodedString()
        #expect(samePath(reference.resolve(), file))
    }

    @Test func isNilOnceTheFileIsGone() throws {
        let (folder, file) = try makeFile()
        let reference = PDFReference.make(for: file, title: "Paper")
        try FileManager.default.removeItem(at: folder)
        #expect(reference.resolve() == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let (folder, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = PDFReference.make(for: file, id: "A", title: "論文")
        let decoded = try JSONDecoder().decode(PDFReference.self, from: JSONEncoder().encode(reference))
        #expect(decoded == reference)
    }
}
