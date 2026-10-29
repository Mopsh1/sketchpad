import SwiftUI

@main
struct SketchpadApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SketchpadDocument()) { file in
            CanvasView(document: file.$document)
        }
        .defaultSize(width: 1280, height: 820)
    }
}
