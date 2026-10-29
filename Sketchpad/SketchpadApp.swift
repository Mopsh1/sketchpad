import SwiftUI

@main
struct SketchpadApp: App {
    init() {
        // Launching, or clicking the Dock icon with no window open, starts a blank untitled board
        // instead of the Open panel macOS shows document apps by default; the first ⌘S asks where to
        // save it. AppKit reads this default itself; implementing applicationOpenUntitledFile in an
        // NSApplicationDelegateAdaptor had no effect (tried: the Open panel still came up).
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
    }

    var body: some Scene {
        DocumentGroup(newDocument: SketchpadDocument()) { file in
            CanvasView(document: file.$document)
        }
        .defaultSize(width: 1280, height: 820)
    }
}
