import SwiftUI

/// What the native controls show about the canvas, reported by the page ("ui" in web/src/bridge.ts).
struct CanvasUI: Equatable, Decodable {
    var tool = "selection"
    var locked = false
    var zoom = 1.0
    var canUndo = false
    var canRedo = false
    var grid = false
    var snap = false
    var zen = false
    var viewMode = false
    var background = "#ffffff"

    init() {}

    init?(_ object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let state = try? JSONDecoder().decode(CanvasUI.self, from: data) else { return nil }
        self = state
    }
}

/// The pattern drawn under every board (web/src/background.ts), kept in the app's settings.
enum CanvasPattern: String, CaseIterable, Identifiable {
    case none, dots, grid

    static let key = "canvasPattern"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "無"
        case .dots: "點點"
        case .grid: "方格"
        }
    }
}

/// A toolbar or menu command, run by the page (web/src/commands.ts). Excalidraw keeps handling its
/// own keyboard shortcuts for all of these while the canvas has focus.
enum CanvasCommand {
    case tool(String)
    case lock
    case zoomIn, zoomOut, resetZoom, zoomToFit
    case undo, redo
    case export, help, library, search
    case background(String)
    case grid, snap, zen, viewMode

    var name: String {
        switch self {
        case .tool: "tool"
        case .lock: "lock"
        case .zoomIn: "zoomIn"
        case .zoomOut: "zoomOut"
        case .resetZoom: "resetZoom"
        case .zoomToFit: "zoomToFit"
        case .undo: "undo"
        case .redo: "redo"
        case .export: "export"
        case .help: "help"
        case .library: "library"
        case .search: "search"
        case .background: "background"
        case .grid: "grid"
        case .snap: "snap"
        case .zen: "zen"
        case .viewMode: "viewMode"
        }
    }

    var argument: String? {
        switch self {
        case .tool(let value), .background(let value): value
        default: nil
        }
    }
}

/// An Excalidraw tool, by its `ToolType`, with Excalidraw's own shortcut keys and what its hint text
/// says (shown as the button's tooltip; native.css hides the hint line under the toolbar).
struct CanvasTool: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: String
    let hint: String

    /// The tools of Excalidraw's toolbar, in its order. Letter symbols follow the app's Chinese
    /// localization: text.cursor shows as 字| (textformat would show as 格式).
    static let main = [
        CanvasTool(id: "selection", title: "選取", symbol: "cursorarrow", keys: "V 或 1",
                   hint: "點選或框選物件；按住空白鍵拖曳可以移動畫布"),
        CanvasTool(id: "hand", title: "移動畫布", symbol: "hand.raised", keys: "H",
                   hint: "拖曳移動畫布；用其他工具時，按住空白鍵拖曳也可以"),
        CanvasTool(id: "rectangle", title: "矩形", symbol: "rectangle", keys: "R 或 2",
                   hint: "拖曳畫出矩形；按住 ⇧ 畫正方形"),
        CanvasTool(id: "diamond", title: "菱形", symbol: "diamond", keys: "D 或 3",
                   hint: "拖曳畫出菱形；按住 ⇧ 保持比例"),
        CanvasTool(id: "ellipse", title: "橢圓", symbol: "circle", keys: "O 或 4",
                   hint: "拖曳畫出橢圓；按住 ⇧ 畫正圓"),
        CanvasTool(id: "arrow", title: "箭頭", symbol: "arrow.up.right", keys: "A 或 5",
                   hint: "拖曳畫直線箭頭，或逐點點擊畫折線"),
        CanvasTool(id: "line", title: "線條", symbol: "line.diagonal", keys: "L 或 6",
                   hint: "拖曳畫直線，或逐點點擊畫折線"),
        CanvasTool(id: "freedraw", title: "畫筆", symbol: "pencil.and.scribble", keys: "P 或 7",
                   hint: "按住拖曳來畫，放開即結束"),
        CanvasTool(id: "text", title: "文字", symbol: "text.cursor", keys: "T 或 8",
                   hint: "點一下開始輸入；用選取工具在任何地方點兩下也可以"),
        CanvasTool(id: "image", title: "圖片", symbol: "photo", keys: "9",
                   hint: "選擇要放進白板的圖片"),
        CanvasTool(id: "eraser", title: "橡皮擦", symbol: "eraser", keys: "E 或 0",
                   hint: "拖過要刪除的物件；按住 ⌥ 可以取消標記"),
    ]

    /// The tools of Excalidraw's "more tools" menu.
    static let more = [
        CanvasTool(id: "frame", title: "框架", symbol: "rectangle.dashed", keys: "F",
                   hint: "拖曳畫出框架，把物件放進去就成為一組"),
        CanvasTool(id: "embeddable", title: "網頁嵌入", symbol: "globe", keys: "",
                   hint: "拖曳畫出嵌入網頁的區域"),
        CanvasTool(id: "laser", title: "雷射筆", symbol: "cursorarrow.rays", keys: "K",
                   hint: "簡報時指示用，筆跡會自己消失"),
    ]

    var help: String { (keys.isEmpty ? title : "\(title)（\(keys)）") + "\n" + hint }
}

/// The board window's toolbar, in place of Excalidraw's (which web/src/native.css hides). Every item
/// can be removed or moved with View ▸ Customize Toolbar.
struct CanvasToolbar: CustomizableToolbarContent {
    let session: BoardSession

    private var ui: CanvasUI { session.canvasUI }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "tools", placement: .principal) {
            // No segment is selected while a tool from the "more tools" menu is in use.
            Picker("工具", selection: Binding<String?>(
                get: { CanvasTool.main.contains { $0.id == ui.tool } ? ui.tool : nil },
                set: { if let tool = $0 { session.perform(.tool(tool)) } }
            )) {
                ForEach(CanvasTool.main) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                        .help(tool.help)
                        .tag(Optional(tool.id))
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(ui.viewMode)
        }

        ToolbarItem(id: "more", placement: .principal) {
            let active = CanvasTool.more.first { $0.id == ui.tool }
            Menu {
                ForEach(CanvasTool.more) { tool in
                    Toggle(isOn: Binding(get: { ui.tool == tool.id }, set: { _ in session.perform(.tool(tool.id)) })) {
                        Label(tool.title, systemImage: tool.symbol)
                    }
                }
            } label: {
                Label("更多工具", systemImage: active?.symbol ?? "ellipsis.circle")
            }
            .help(active?.help ?? "更多工具")
            .disabled(ui.viewMode)
        }

        ToolbarItem(id: "lock", placement: .principal) {
            Toggle(isOn: Binding(get: { ui.locked }, set: { _ in session.perform(.lock) })) {
                Label("保持工具", systemImage: ui.locked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .help("畫完後保持目前的工具（Q）")
            .disabled(ui.viewMode)
        }

        ToolbarItem(id: "zoom", placement: .primaryAction) {
            ControlGroup {
                Button("縮小", systemImage: "minus.magnifyingglass") { session.perform(.zoomOut) }
                    .help("縮小（⌘−）")
                Menu("\(Int((ui.zoom * 100).rounded()))%") {
                    Button("實際大小") { session.perform(.resetZoom) }
                    Button("縮放至全部內容") { session.perform(.zoomToFit) }
                }
                .help("縮放比例")
                Button("放大", systemImage: "plus.magnifyingglass") { session.perform(.zoomIn) }
                    .help("放大（⌘=）")
            } label: {
                Label("縮放", systemImage: "magnifyingglass")
            }
        }

        ToolbarItem(id: "library", placement: .primaryAction) {
            Button("資料庫", systemImage: "books.vertical") { session.perform(.library) }
                .help("資料庫")
        }

        ToolbarItem(id: "export", placement: .primaryAction) {
            Button("匯出圖片", systemImage: "square.and.arrow.up") { session.perform(.export) }
                .help("匯出圖片（⇧⌘E）")
        }

        ToolbarItem(id: "reader", placement: .primaryAction) {
            Toggle(isOn: Binding(get: { session.isReaderShown }, set: { session.isReaderShown = $0 })) {
                Label("閱讀面板", systemImage: "text.page")
            }
            .toggleStyle(.button)
            .help("顯示或隱藏閱讀面板（⌥⌘I）")
        }
    }
}
