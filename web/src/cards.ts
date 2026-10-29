// Cards the Swift side asks for: the PDF card, quote cards and region cards. Their data
// (`customData.sketchpad`) is described by CardData in Sketchpad/SceneCards.swift; this file only
// turns it into ordinary Excalidraw elements, so boards still open on excalidraw.com.
import {
  CaptureUpdateAction,
  convertToExcalidrawElements,
  FONT_FAMILY,
  newElementWith,
  ROUNDNESS,
  viewportCoordsToSceneCoords,
} from "@excalidraw/excalidraw";
import type { ExcalidrawElementSkeleton } from "@excalidraw/excalidraw/data/transform";
import type { ExcalidrawElement, FileId } from "@excalidraw/excalidraw/element/types";
import type { BinaryFileData, DataURL, ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

export type CardSpec = {
  /** CardData, stored on the card element as `customData.sketchpad`. */
  card: { pdf?: { id?: string } };
  link: string;
  /** Where the card goes, in web view pixels (a drop point); the middle of the view when absent. */
  at?: { clientX: number; clientY: number };
  /** Text of a quote card. */
  quote?: string;
  /** Image of a PDF or region card, at its board size. */
  image?: { dataURL: string; width: number; height: number };
  /** Text under the image, grouped with it. */
  caption?: string;
};

export type PreparedCard = { fileId: FileId | null };

const FONT_SIZE = 16;
// Cards use the normal font and smooth lines, like new drawings (bridge.ts).
const FONT = FONT_FAMILY.Nunito;
// What Excalidraw's getFontString gives for Nunito (not exported): only an emoji fallback, so Chinese
// is drawn in the system font.
const FONT_FAMILIES = "Nunito, Segoe UI Emoji";
const FONT_TIMEOUT_MS = 3000;
const QUOTE_WIDTH = 320;
const QUOTE_BACKGROUND = "#fff9db";
const CAPTION_GAP = 8;
const CARD_GAP = 16;

/**
 * The asynchronous part of inserting a card, done before touching the scene.
 *
 * Excalidraw loads fonts only when a scene is initialized, and measures text (line wrapping, container
 * height) when the element is created. New text has to have its glyphs loaded first, or it is laid
 * out and drawn in a fallback font. Excalidraw's own font switcher does the same `document.fonts.load`.
 */
export async function prepareCard(spec: CardSpec): Promise<PreparedCard> {
  const text = `${spec.quote ?? ""}${spec.caption ?? ""}`;
  if (text) {
    await Promise.race([
      document.fonts.load(`${FONT_SIZE}px ${FONT_FAMILIES}`, text).catch(() => []),
      new Promise((resolve) => window.setTimeout(resolve, FONT_TIMEOUT_MS)),
    ]);
  }
  return { fileId: spec.image ? await fileIdFor(spec.image.dataURL) : null };
}

/** Adds the card as one undo step and selects it; returns the id of the element carrying the card data. */
export function addCard(api: ExcalidrawImperativeAPI, spec: CardSpec, prepared: PreparedCard): string | null {
  const customData = { sketchpad: spec.card };
  const skeletons: ExcalidrawElementSkeleton[] = [];
  if (spec.quote !== undefined) {
    // No height: Excalidraw grows the rectangle to fit the wrapped text.
    skeletons.push({
      type: "rectangle",
      x: 0,
      y: 0,
      width: QUOTE_WIDTH,
      backgroundColor: QUOTE_BACKGROUND,
      fillStyle: "solid",
      roughness: 0,
      roundness: { type: ROUNDNESS.ADAPTIVE_RADIUS },
      link: spec.link,
      customData,
      label: {
        text: spec.quote,
        fontSize: FONT_SIZE,
        fontFamily: FONT,
        textAlign: "left",
        verticalAlign: "top",
      },
    });
  } else if (spec.image && prepared.fileId) {
    api.addFiles([
      {
        id: prepared.fileId,
        dataURL: spec.image.dataURL as DataURL,
        mimeType: mimeTypeOf(spec.image.dataURL),
        created: Date.now(),
      },
    ]);
    const groupIds = spec.caption ? [randomId()] : [];
    skeletons.push({
      type: "image",
      x: 0,
      y: 0,
      width: spec.image.width,
      height: spec.image.height,
      fileId: prepared.fileId,
      status: "saved",
      link: spec.link,
      customData,
      groupIds,
    });
    if (spec.caption) {
      skeletons.push({
        type: "text",
        x: 0,
        y: spec.image.height + CAPTION_GAP,
        text: spec.caption,
        fontSize: FONT_SIZE,
        fontFamily: FONT,
        groupIds,
      });
    }
  } else {
    return null;
  }

  const created = convertToExcalidrawElements(skeletons);
  const { dx, dy } = placement(api, spec.at, boundsOf(created));
  // Fresh elements nobody else holds yet, so moving them by copy is enough.
  const placed = created.map((element) => ({ ...element, x: element.x + dx, y: element.y + dy }));
  const card = placed.find((element) => element.customData?.sketchpad);
  if (!card) return null;

  api.updateScene({
    elements: [...api.getSceneElementsIncludingDeleted(), ...placed],
    appState: selectionOf(placed, card),
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
  const bounds = boundsOf(placed);
  lastCard = { id: card.id, left: bounds.minX - card.x, bottom: bounds.maxY - card.y };
  // Not animated: the next card is placed by what is in view, which must already be final when a
  // quote follows right after this one.
  if (!contains(visibleBounds(api), bounds)) {
    api.scrollToContent(placed, { fitToContent: false, animate: false });
  }
  return card.id;
}

/**
 * Scrolls the board to an element, or to a group (element links can name either), and selects it,
 * without zooming and without an undo step.
 */
export function revealElement(api: ExcalidrawImperativeAPI, id: string): boolean {
  const elements = api.getSceneElements();
  const element = elements.find((candidate) => candidate.id === id);
  const targets = element ? [element] : elements.filter((candidate) => candidate.groupIds.includes(id));
  if (targets.length === 0) return false;
  api.scrollToContent(targets, { fitToContent: false, animate: true });
  const selection = element
    ? selectionOf(elements, element)
    : { selectedElementIds: idSet(targets), selectedGroupIds: { [id]: true }, editingGroupId: null };
  api.updateScene({ appState: selection, captureUpdate: CaptureUpdateAction.NEVER });
  return true;
}

/**
 * What clicking the element would select: its outermost group (the last of its groupIds) when it has
 * one, so a PDF card's image and caption move and delete together.
 */
function selectionOf(elements: readonly ExcalidrawElement[], element: ExcalidrawElement) {
  // Leaves any group the user had entered for editing.
  const groupId = element.groupIds.at(-1);
  if (!groupId) return { selectedElementIds: idSet([element]), selectedGroupIds: {}, editingGroupId: null };
  const members = elements.filter((candidate) => candidate.groupIds.includes(groupId));
  return { selectedElementIds: idSet(members), selectedGroupIds: { [groupId]: true }, editingGroupId: null };
}

function idSet(elements: readonly ExcalidrawElement[]): Record<string, true> {
  return Object.fromEntries(elements.map((element) => [element.id, true as const]));
}

/** Points every card of one PDF at a new file location, as one undo step. */
export function relinkPDF(api: ExcalidrawImperativeAPI, pdfId: string, pdf: unknown): number {
  let changed = 0;
  const elements = api.getSceneElementsIncludingDeleted().map((element) => {
    const card = element.customData?.sketchpad;
    if (card?.pdf?.id !== pdfId) return element;
    changed += 1;
    return newElementWith(element, { customData: { ...element.customData, sketchpad: { ...card, pdf } } });
  });
  if (changed > 0) api.updateScene({ elements, captureUpdate: CaptureUpdateAction.IMMEDIATELY });
  return changed;
}

/**
 * The card inserted last, with its group's left and bottom edges relative to the card element, so the
 * next card can line up under it even after the user moved it.
 */
let lastCard: { id: string; left: number; bottom: number } | null = null;

type Bounds = { minX: number; minY: number; maxX: number; maxY: number };

/**
 * How far to move a new card from where it was built. A drop centres it on the drop point. Otherwise
 * it goes under the card inserted last while that one is in view, so quotes taken while reading form
 * a column; failing that, it is centred in the view.
 */
function placement(api: ExcalidrawImperativeAPI, at: CardSpec["at"], bounds: Bounds) {
  const appState = api.getAppState();
  if (at) {
    return centreOn(viewportCoordsToSceneCoords(at, appState), bounds);
  }
  const previous = lastCard && api.getSceneElements().find((element) => element.id === lastCard?.id);
  if (lastCard && previous && intersects(visibleBounds(api), boundsOf([previous]))) {
    return {
      dx: previous.x + lastCard.left - bounds.minX,
      dy: previous.y + lastCard.bottom + CARD_GAP - bounds.minY,
    };
  }
  const centre = viewportCoordsToSceneCoords(
    { clientX: appState.offsetLeft + appState.width / 2, clientY: appState.offsetTop + appState.height / 2 },
    appState,
  );
  return centreOn(centre, bounds);
}

function centreOn(point: { x: number; y: number }, bounds: Bounds) {
  return { dx: point.x - (bounds.minX + bounds.maxX) / 2, dy: point.y - (bounds.minY + bounds.maxY) / 2 };
}

/** The part of the board on screen, in scene coordinates. */
function visibleBounds(api: ExcalidrawImperativeAPI): Bounds {
  const appState = api.getAppState();
  const topLeft = viewportCoordsToSceneCoords({ clientX: appState.offsetLeft, clientY: appState.offsetTop }, appState);
  const bottomRight = viewportCoordsToSceneCoords(
    { clientX: appState.offsetLeft + appState.width, clientY: appState.offsetTop + appState.height },
    appState,
  );
  return { minX: topLeft.x, minY: topLeft.y, maxX: bottomRight.x, maxY: bottomRight.y };
}

function intersects(a: Bounds, b: Bounds) {
  return a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;
}

function contains(outer: Bounds, inner: Bounds) {
  return outer.minX <= inner.minX && outer.minY <= inner.minY && outer.maxX >= inner.maxX && outer.maxY >= inner.maxY;
}

function boundsOf(elements: readonly ExcalidrawElement[]): Bounds {
  return {
    minX: Math.min(...elements.map((element) => element.x)),
    minY: Math.min(...elements.map((element) => element.y)),
    maxX: Math.max(...elements.map((element) => element.x + element.width)),
    maxY: Math.max(...elements.map((element) => element.y + element.height)),
  };
}

/** Same content, same id, the way Excalidraw names files it reads itself (a SHA-1 hex digest). */
async function fileIdFor(dataURL: string): Promise<FileId> {
  const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(dataURL));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("") as FileId;
}

function mimeTypeOf(dataURL: string): BinaryFileData["mimeType"] {
  return (dataURL.match(/^data:([^;,]+)/)?.[1] ?? "image/png") as BinaryFileData["mimeType"];
}

function randomId() {
  return Array.from(crypto.getRandomValues(new Uint8Array(10)), (byte) => byte.toString(36)).join("");
}
