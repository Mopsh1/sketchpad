// Link between Excalidraw and the Swift side (Sketchpad/CanvasView.swift).
//
// Swift → page: once the page reports "ready", Swift calls `window.sketchpad.load(scene)` with the
// document's JSON, and again whenever the document changes on its own side (File ▸ Revert To).
// Page → Swift: after edits settle, the page posts the serialized scene as a "change" message.
//
// Scenes reach Excalidraw as `initialData` (see App.tsx), never through `updateScene`: only scene
// initialization loads the fonts the scene's text uses, so `updateScene` leaves text in a fallback font.
// Adding cards to the current scene is different: cards.ts loads their fonts first, then appends them
// with `updateScene`, which keeps Excalidraw's undo history.
//
// PDF reading (Sketchpad/BoardSession.swift):
// - Swift → page: `insertCard(spec)` adds a card and returns its element id (null while a load is in
//   progress); `reveal(id)` scrolls to an element and selects it; `relinkPDF(pdfId, pdf)` points one
//   PDF's cards at a moved file.
// - Page → Swift: clicking a card's link posts "openPDF" with the card data; any other link posts
//   "openLink", because Excalidraw's own window.open would reach Swift only as about:blank.
//
// Native toolbar and menus (Sketchpad/CanvasToolbar.swift, commands.ts):
// - Swift → page: `command(name, arg)` runs a toolbar or menu command; `setAccent(light, dark)` passes
//   the system accent color for native.css.
// - Page → Swift: "ui" with what the controls show (current tool, zoom, undo availability, toggles),
//   sent whenever it changes.
//
// In a normal browser (`npm run dev`) there is no message handler, so the page just runs standalone.
import { CaptureUpdateAction, FONT_FAMILY, isElementLink, loadFromBlob, serializeAsJSON } from "@excalidraw/excalidraw";
import type { NonDeletedExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type { AppState, ExcalidrawImperativeAPI, ExcalidrawInitialDataState } from "@excalidraw/excalidraw/types";
import { addCard, type CardSpec, prepareCard, relinkPDF as relinkCards, revealElement } from "./cards";
import { isTransparent, paint, setPattern, toOpaque, toTransparent } from "./background";
import { type CanvasUI, canvasUI, runCommand } from "./commands";

type NativeMessage =
  | { type: "ready"; isSecureContext: boolean; hasSubtleCrypto: boolean; origin: string }
  | { type: "change"; scene: string }
  | { type: "ui"; state: CanvasUI }
  | { type: "openPDF"; elementId: string; card: unknown }
  | { type: "openLink"; url: string }
  | { type: "log"; level: "info" | "error"; message: string };

declare global {
  interface Window {
    webkit?: { messageHandlers?: Record<string, { postMessage(message: unknown): void }> };
    sketchpad?: {
      load(scene: string): Promise<void>;
      insertCard(spec: CardSpec): Promise<string | null>;
      reveal(id: string): boolean;
      relinkPDF(pdfId: string, pdf: unknown): number;
      command(name: string, arg?: unknown): boolean;
      setAccent(light: string, dark: string): void;
      setPattern(pattern: string): void;
    };
  }
}

const native = window.webkit?.messageHandlers?.sketchpad;

// onChange fires on every pointer move while drawing; wait for a short pause before serializing.
// Kept short because keyboard edits have no pointerup to flush them before the window closes.
const SYNC_DELAY_MS = 100;

// The current Excalidraw instance; null while a reload is replacing it, so the outgoing board's
// events are ignored.
let api: ExcalidrawImperativeAPI | null = null;
// The scene Swift already has, serialized from what it sent. onChange also fires for scrolling,
// selection and font loading, so an edit is only reported when the serialized scene differs from
// this. null until the first load and while a load is in progress, which pauses syncing.
let baseline: string | null = null;
let syncTimer: number | undefined;
let loadCount = 0;
// Where the user was looking before a reload, restored on the new board.
let view: Pick<AppState, "scrollX" | "scrollY" | "zoom"> | null = null;
// Defaults for new elements (the `currentItem…` fields): smooth lines and the normal font, whose
// Chinese falls back to the system font. Excalidraw does not save these in the file, so every board
// starts from them; a reload keeps whatever was picked in the properties panel since.
let styleDefaults: Partial<AppState> = { currentItemRoughness: 0, currentItemFontFamily: FONT_FAMILY.Nunito };
// The last "ui" message, to send only changes.
let lastUI = "";
let uiFrame = 0;

let resolveFirstScene: (scene: ExcalidrawInitialDataState | null) => void = () => {};
/** What Excalidraw starts with: the document Swift sends first, or an empty board in a plain browser. */
export const firstScene: Promise<ExcalidrawInitialDataState | null> = native
  ? new Promise((resolve) => (resolveFirstScene = resolve))
  : Promise.resolve({ appState: { ...styleDefaults, viewBackgroundColor: toTransparent("#ffffff") } });
let firstSceneLoaded = false;

let reloadListener: ((scene: ExcalidrawInitialDataState) => void) | null = null;
/** App.tsx remounts Excalidraw with the scene passed here when Swift pushes a later change. */
export function onSceneReload(listener: (scene: ExcalidrawInitialDataState) => void) {
  reloadListener = listener;
}

function post(message: NativeMessage) {
  native?.postMessage(message);
}

/** Excalidraw's `excalidrawAPI` callback; runs again for each remount. */
export function attach(instance: ExcalidrawImperativeAPI) {
  api = instance;
  // Report a finished stroke right away, so closing the window just after drawing loses nothing.
  instance.onPointerUp(() => sync());
  // A remount (File ▸ Revert To) brings new undo buttons with an empty history, which no attribute
  // change announces.
  scheduleUIReport();
}

export function sceneChanged(_elements: unknown, appState: AppState) {
  paint(appState);
  keepExportOpaque(appState);
  reportUI(appState);
  window.clearTimeout(syncTimer);
  syncTimer = window.setTimeout(sync, SYNC_DELAY_MS);
}

function reportUI(appState: AppState | undefined = api?.getAppState()) {
  if (!appState) return;
  const state = canvasUI(appState);
  const json = JSON.stringify(state);
  if (json === lastUI) return;
  lastUI = json;
  post({ type: "ui", state });
}

function scheduleUIReport() {
  if (uiFrame) return;
  uiFrame = window.requestAnimationFrame(() => {
    uiFrame = 0;
    reportUI();
  });
}

// Undo and redo availability lives in Excalidraw's history, which re-renders its buttons without
// necessarily firing onChange; watch the buttons' disabled attribute instead. Focus moving into or out
// of a text field changes what Edit ▸ Undo does (commands.ts).
new MutationObserver(scheduleUIReport).observe(document.body, {
  subtree: true,
  attributes: true,
  attributeFilter: ["disabled"],
});
document.addEventListener("focusin", scheduleUIReport);
document.addEventListener("focusout", scheduleUIReport);

function sync() {
  window.clearTimeout(syncTimer);
  if (!api || baseline === null) return;
  const appState = api.getAppState();
  const scene = serializeAsJSON(
    api.getSceneElements(),
    { ...appState, viewBackgroundColor: toOpaque(appState.viewBackgroundColor) },
    api.getFiles(),
    "local",
  );
  if (scene === baseline) return;
  baseline = scene;
  post({ type: "change", scene });
}

async function load(scene: string) {
  const thisLoad = ++loadCount;
  // Whatever the current board has not reported yet is being replaced; drop it.
  window.clearTimeout(syncTimer);
  baseline = null;
  if (api) {
    const appState = api.getAppState();
    const { scrollX, scrollY, zoom } = appState;
    view = { scrollX, scrollY, zoom };
    styleDefaults = Object.fromEntries(
      Object.entries(appState).filter(([key]) => key.startsWith("currentItem")),
    ) as Partial<AppState>;
  }
  if (firstSceneLoaded) api = null;
  const data = await loadFromBlob(new Blob([scene], { type: "application/json" }), null, null);
  // Swift pushed a newer scene while this one was parsing.
  if (thisLoad !== loadCount) return;
  baseline = serializeAsJSON(data.elements, data.appState, data.files, "local");
  // What the board starts with besides the file: the default style for new elements, and the scene
  // color made transparent so the background layer shows through (background.ts).
  const board = {
    ...styleDefaults,
    viewBackgroundColor: toTransparent(data.appState.viewBackgroundColor ?? "#ffffff"),
  };
  if (!firstSceneLoaded) {
    firstSceneLoaded = true;
    resolveFirstScene({ ...data, appState: { ...data.appState, ...board }, scrollToContent: true });
    return;
  }
  // A later push (File ▸ Revert To) replaces the board but keeps the view where it was.
  reloadListener?.({ ...data, appState: { ...data.appState, ...board, ...view } });
}

function command(name: string, arg?: unknown) {
  return api ? runCommand(api, name, arg) : false;
}

// Excalidraw exports the scene's own color, which is transparent while the board shows. The export
// command opens the dialog with the opaque one (commands.ts); this takes it back when the dialog closes.
// Neither is an undo step. A dialog opened some other way gets the opaque color here, but its preview
// may already show it transparent.
let exportingOpaque = false;
function keepExportOpaque(appState: AppState) {
  if (!api) return;
  const exporting = appState.openDialog?.name === "imageExport";
  const color = appState.viewBackgroundColor;
  if (exporting && !exportingOpaque) {
    exportingOpaque = true;
    if (isTransparent(color)) {
      api.updateScene({ appState: { viewBackgroundColor: toOpaque(color) }, captureUpdate: CaptureUpdateAction.NEVER });
    }
  } else if (!exporting && exportingOpaque) {
    exportingOpaque = false;
    api.updateScene({ appState: { viewBackgroundColor: toTransparent(color) }, captureUpdate: CaptureUpdateAction.NEVER });
  }
}

// Excalidraw's own ⇧⌘E would open the dialog with the transparent color; send it through the command.
// Capture phase, so it runs before Excalidraw's handler.
document.addEventListener(
  "keydown",
  (event) => {
    if (!api || event.key.toLowerCase() !== "e" || !event.shiftKey || !(event.metaKey || event.ctrlKey)) return;
    event.preventDefault();
    event.stopPropagation();
    command("export");
  },
  true,
);

function setAccent(light: string, dark: string) {
  const root = document.documentElement.style;
  root.setProperty("--sketchpad-accent", light);
  root.setProperty("--sketchpad-accent-dark", dark);
}

async function insertCard(spec: CardSpec): Promise<string | null> {
  // View mode is read-only: no cards from the reader, the menu or a dropped PDF.
  if (!api || baseline === null || api.getAppState().viewModeEnabled) return null;
  const thisLoad = loadCount;
  const prepared = await prepareCard(spec);
  // A new scene arrived while the fonts loaded; the card was meant for the old one.
  if (!api || baseline === null || thisLoad !== loadCount) return null;
  const id = addCard(api, spec, prepared);
  // Report it now rather than after the debounce, which the scroll animation that may follow keeps
  // restarting; closing the window right after adding a card must not lose it.
  sync();
  return id;
}

function reveal(id: string) {
  return api ? revealElement(api, id) : false;
}

function relinkPDF(pdfId: string, pdf: unknown) {
  if (!api || baseline === null) return 0;
  const changed = relinkCards(api, pdfId, pdf);
  sync();
  return changed;
}

/** Excalidraw's `onLinkOpen`: in the app, every link is handled here or by Swift. */
export function linkOpened(element: NonDeletedExcalidrawElement, event: CustomEvent<unknown>) {
  // A plain browser opens links itself.
  if (!native) return;
  event.preventDefault();
  const link = element.link ?? "";
  // "Link to element" points inside this board; following it would reload the page.
  if (isElementLink(link)) {
    const id = new URL(link).searchParams.get("element");
    if (id) reveal(id);
    return;
  }
  const card = element.customData?.sketchpad;
  if (card) {
    post({ type: "openPDF", elementId: element.id, card });
  } else if (link) {
    post({ type: "openLink", url: link });
  }
}

window.sketchpad = { load, insertCard, reveal, relinkPDF, command, setAccent, setPattern };

window.addEventListener("error", (event) => {
  post({ type: "log", level: "error", message: `${event.message} (${event.filename}:${event.lineno})` });
});
window.addEventListener("unhandledrejection", (event) => {
  post({ type: "log", level: "error", message: `Unhandled rejection: ${String(event.reason)}` });
});
document.fonts.addEventListener("loadingerror", (event) => {
  const families = event.fontfaces.map((face) => face.family).join(", ");
  post({ type: "log", level: "error", message: `Font failed to load: ${families}` });
});

post({
  type: "ready",
  isSecureContext: window.isSecureContext,
  hasSubtleCrypto: Boolean(window.crypto?.subtle),
  origin: location.origin,
});
