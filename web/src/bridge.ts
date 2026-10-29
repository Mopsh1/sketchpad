// Link between Excalidraw and the Swift side (Sketchpad/CanvasView.swift).
//
// Swift → page: once the page reports "ready", Swift calls `window.sketchpad.load(scene)` with the
// document's JSON, and again whenever the document changes on its own side (revert, Edit ▸ Undo).
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
// In a normal browser (`npm run dev`) there is no message handler, so the page just runs standalone.
import { isElementLink, loadFromBlob, serializeAsJSON } from "@excalidraw/excalidraw";
import type { NonDeletedExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type { AppState, ExcalidrawImperativeAPI, ExcalidrawInitialDataState } from "@excalidraw/excalidraw/types";
import { addCard, type CardSpec, prepareCard, relinkPDF as relinkCards, revealElement } from "./cards";

type NativeMessage =
  | { type: "ready"; isSecureContext: boolean; hasSubtleCrypto: boolean; origin: string }
  | { type: "change"; scene: string }
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

let resolveFirstScene: (scene: ExcalidrawInitialDataState | null) => void = () => {};
/** What Excalidraw starts with: the document Swift sends first, or an empty board in a plain browser. */
export const firstScene: Promise<ExcalidrawInitialDataState | null> = native
  ? new Promise((resolve) => (resolveFirstScene = resolve))
  : Promise.resolve(null);
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
}

export function sceneChanged() {
  window.clearTimeout(syncTimer);
  syncTimer = window.setTimeout(sync, SYNC_DELAY_MS);
}

function sync() {
  window.clearTimeout(syncTimer);
  if (!api || baseline === null) return;
  const scene = serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local");
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
    const { scrollX, scrollY, zoom } = api.getAppState();
    view = { scrollX, scrollY, zoom };
  }
  if (firstSceneLoaded) api = null;
  const data = await loadFromBlob(new Blob([scene], { type: "application/json" }), null, null);
  // Swift pushed a newer scene while this one was parsing.
  if (thisLoad !== loadCount) return;
  baseline = serializeAsJSON(data.elements, data.appState, data.files, "local");
  if (!firstSceneLoaded) {
    firstSceneLoaded = true;
    resolveFirstScene({ ...data, scrollToContent: true });
    return;
  }
  // A later push (revert, Edit ▸ Undo) replaces the board but keeps the view where it was.
  reloadListener?.({ ...data, appState: { ...data.appState, ...view } });
}

async function insertCard(spec: CardSpec): Promise<string | null> {
  if (!api || baseline === null) return null;
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

window.sketchpad = { load, insertCard, reveal, relinkPDF };

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
