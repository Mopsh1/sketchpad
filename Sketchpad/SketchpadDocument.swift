import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Excalidraw's scene format, declared in project.yml as an imported type.
    static let excalidraw = UTType(importedAs: "com.excalidraw.excalidraw")
}

/// One board, kept as its serialized .excalidraw JSON. The web page owns the parsed scene;
/// this side only stores the text and lets DocumentGroup save it.
struct SketchpadDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.excalidraw]

    /// The smallest scene excalidraw.com accepts, so a new, untouched file still opens there.
    static let emptyScene = """
        {
          "type": "excalidraw",
          "version": 2,
          "elements": [],
          "appState": {},
          "files": {}
        }
        """

    var scene: String

    init(scene: String = SketchpadDocument.emptyScene) {
        self.scene = scene
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scene = try Self.scene(from: data)
    }

    /// Checks the file is an Excalidraw scene before the page sees it, so a broken file gets the
    /// standard "can't be opened" alert instead of a board stuck loading.
    static func scene(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "excalidraw" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(scene.utf8))
    }
}
