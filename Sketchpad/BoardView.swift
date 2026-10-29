import SwiftUI

/// One board window: the canvas under a native toolbar, with the PDF reader as an inspector on the right.
struct BoardView: View {
    @Binding var document: SketchpadDocument
    @State private var session = BoardSession()
    @AppStorage(CanvasPattern.key) private var pattern = CanvasPattern.none.rawValue

    var body: some View {
        CanvasView(document: $document, session: session, pattern: pattern)
            // Narrower or lower than this, Excalidraw switches to its phone layout, which native.css
            // does not cover and which drops the zoom and undo buttons the menu commands click.
            .frame(minWidth: 760, minHeight: 540)
            .inspector(isPresented: $session.isReaderShown) {
                PDFReaderView(session: session)
                    .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
            }
            .toolbar(id: "board") { CanvasToolbar(session: session) }
            .toolbarRole(.editor)
            // A scene value: the web view holds keyboard focus, which SwiftUI's focus system cannot see.
            .focusedSceneValue(\.board, session)
    }
}

extension FocusedValues {
    @Entry var board: BoardSession?
}

/// Menu commands for the board in the front window.
///
/// The page sees key presses before the menus do, and Excalidraw handles its own shortcuts (⌘Z, ⌘=,
/// ⌘F, ⇧⌘E, …), so with the canvas focused a menu shortcut that matches one of them never fires twice;
/// the menu item runs when something else has focus, such as the reader. New shortcuts avoid keys
/// Excalidraw uses for something else: ⇧⌘P is its command palette and ⇧H flips a selection. Toggles
/// that Excalidraw binds to ⌥ or ⇧ alone (snapping ⌥S, zen ⌥Z, ⇧1) get no menu shortcut, which would
/// also fire while typing in a text field.
struct BoardCommands: Commands {
    @FocusedValue(\.board) private var board

    @AppStorage(CanvasPattern.key) private var pattern = CanvasPattern.none.rawValue

    /// Background colors for reading, saved in the board. Excalidraw's dark theme inverts them.
    private static let backgrounds = [
        ("白色", "#ffffff"), ("紙張", "#faf8f3"), ("米黃", "#f6efdc"), ("淺灰", "#f2f2f2"), ("淺綠", "#edf3e8"),
    ]

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("插入 PDF⋯") {
                guard let board else { return }
                Task { await board.chooseAndInsertPDF() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(board == nil || board?.canvasUI.viewMode == true)
        }

        CommandGroup(after: .importExport) {
            Button("匯出圖片⋯") { board?.perform(.export) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(board == nil)
        }

        // Undo and redo follow Excalidraw's own history, the one ⌘Z uses on the canvas, one stroke at a
        // time. A text field, such as the reader's search, keeps its own.
        CommandGroup(replacing: .undoRedo) {
            Button("還原") { undoOrRedo(.undo, selector: "undo:") }
                .keyboardShortcut("z")
                .disabled(board != nil && board?.canvasUI.canUndo != true)
            Button("重做") { undoOrRedo(.redo, selector: "redo:") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(board != nil && board?.canvasUI.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("尋找⋯") { board?.zoomOrFind(.search) }
                .keyboardShortcut("f")
                .disabled(board == nil)
        }

        // Zooming and Find act on the PDF while the reader has focus (BoardSession.zoomOrFind).
        CommandGroup(before: .toolbar) {
            Button("放大") { board?.zoomOrFind(.zoomIn) }
                .keyboardShortcut("=")
                .disabled(board == nil)
            Button("縮小") { board?.zoomOrFind(.zoomOut) }
                .keyboardShortcut("-")
                .disabled(board == nil)
            Button("實際大小") { board?.zoomOrFind(.resetZoom) }
                .keyboardShortcut("0")
                .disabled(board == nil)
            Button("縮放至全部內容") { board?.zoomOrFind(.zoomToFit) }
                .disabled(board == nil)
            Divider()
            // Excalidraw's grid, which also snaps; the dot and square backgrounds are only drawn.
            Toggle("對齊格線", isOn: Binding(get: { board?.canvasUI.grid ?? false }, set: { _ in board?.perform(.grid) }))
                .keyboardShortcut("'")
                .disabled(board == nil)
            Toggle("物件貼齊", isOn: Binding(get: { board?.canvasUI.snap ?? false }, set: { _ in board?.perform(.snap) }))
                .disabled(board == nil)
            Toggle("禪模式", isOn: Binding(get: { board?.canvasUI.zen ?? false }, set: { _ in board?.perform(.zen) }))
                .disabled(board == nil)
            Toggle("檢視模式", isOn: Binding(get: { board?.canvasUI.viewMode ?? false }, set: { _ in board?.perform(.viewMode) }))
                .disabled(board == nil)
            Divider()
            // Nothing is checked for a color that is not a preset (picked on excalidraw.com, say).
            Picker("畫布背景", selection: Binding<String?>(
                get: {
                    let current = board?.canvasUI.background.lowercased()
                    return Self.backgrounds.contains { $0.1 == current } ? current : nil
                },
                set: { if let hex = $0 { board?.perform(.background(hex)) } }
            )) {
                ForEach(Self.backgrounds, id: \.1) { name, hex in
                    Text(name).tag(Optional(hex))
                }
            }
            .disabled(board == nil || board?.canvasUI.viewMode == true)
            // An app setting for every board, not saved in the file (web/src/background.ts).
            Picker("畫布圖樣", selection: $pattern) {
                ForEach(CanvasPattern.allCases) { pattern in
                    Text(pattern.title).tag(pattern.rawValue)
                }
            }
            Button("資料庫") { board?.perform(.library) }
                .disabled(board == nil)
            Divider()
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
            .disabled(board?.hasTextSelection != true || board?.canvasUI.viewMode == true)
        }

        CommandGroup(replacing: .help) {
            Button("鍵盤快速鍵") { board?.perform(.help) }
                .disabled(board == nil)
        }
    }

    private func undoOrRedo(_ command: CanvasCommand, selector: String) {
        if let board, !(NSApp.keyWindow?.firstResponder is NSText) {
            board.perform(command)
        } else {
            NSApp.sendAction(Selector(selector), to: nil, from: nil)
        }
    }
}
