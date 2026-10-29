import SwiftUI

/// One board window: the canvas, with the PDF reader as an inspector on the right.
struct BoardView: View {
    @Binding var document: SketchpadDocument
    @State private var session = BoardSession()

    var body: some View {
        CanvasView(document: $document, session: session)
            .inspector(isPresented: $session.isReaderShown) {
                PDFReaderView(session: session)
                    .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
            }
            // A scene value: the web view holds keyboard focus, which SwiftUI's focus system cannot see.
            .focusedSceneValue(\.board, session)
    }
}

extension FocusedValues {
    @Entry var board: BoardSession?
}

/// Menu commands for the board in the front window. Shortcuts avoid keys Excalidraw uses, since the
/// page sees key presses before the menu does: ⇧⌘P is its command palette and ⇧H flips a selection.
struct BoardCommands: Commands {
    @FocusedValue(\.board) private var board

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("插入 PDF⋯") {
                guard let board else { return }
                Task { await board.chooseAndInsertPDF() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(board == nil)
        }
        CommandMenu("閱讀") {
            Button(board?.isReaderShown == true ? "隱藏閱讀面板" : "顯示閱讀面板") {
                board?.isReaderShown.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(board == nil)

            Button("把選取的文字加到白板") {
                guard let board else { return }
                Task { await board.addSelectionToBoard() }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(board?.hasTextSelection != true)
        }
    }
}
