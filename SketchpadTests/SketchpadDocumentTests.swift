import Foundation
import Testing
@testable import Sketchpad

struct SketchpadDocumentTests {
    @Test func acceptsAnExcalidrawSceneAsIs() throws {
        let text = #"{"type":"excalidraw","version":2,"elements":[{"type":"text","text":"白板"}]}"#
        #expect(try SketchpadDocument.scene(from: Data(text.utf8)) == text)
    }

    @Test func newDocumentsAreValidScenes() throws {
        _ = try SketchpadDocument.scene(from: Data(SketchpadDocument.emptyScene.utf8))
    }

    @Test(arguments: [
        "not json",
        #"{"type":"excalidrawlib","libraryItems":[]}"#,
        #"[{"type":"excalidraw"}]"#,
        "",
    ])
    func rejectsFilesThatAreNotScenes(_ text: String) {
        #expect(throws: CocoaError.self) { try SketchpadDocument.scene(from: Data(text.utf8)) }
    }

    @Test func rejectsTextThatIsNotUTF8() {
        let latin1 = Data([0x7B, 0x22, 0xE9, 0x22, 0x7D]) // {"é"} in Latin-1
        #expect(throws: CocoaError.self) { try SketchpadDocument.scene(from: latin1) }
    }
}
