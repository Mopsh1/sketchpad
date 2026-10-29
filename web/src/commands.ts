// Commands from the native window toolbar and menus (Sketchpad/CanvasToolbar.swift, BoardView.swift),
// and the state those controls show.
//
// Excalidraw 0.18.1 has no API for zooming or undoing, so those commands click its own buttons, which
// native.css hides but keeps mounted. A disabled button (nothing to undo, zoomed all the way) ignores
// the click, as it would for a real one.
import { CaptureUpdateAction } from "@excalidraw/excalidraw";
import type { AppState, ExcalidrawImperativeAPI, ToolType } from "@excalidraw/excalidraw/types";
import { toOpaque, toTransparent } from "./background";

/** What the native controls show; sent to Swift as a "ui" message whenever it changes. */
export type CanvasUI = {
  tool: string;
  locked: boolean;
  zoom: number;
  canUndo: boolean;
  canRedo: boolean;
  grid: boolean;
  snap: boolean;
  zen: boolean;
  viewMode: boolean;
  background: string;
};

const TOOLS = new Set<string>([
  "selection",
  "rectangle",
  "diamond",
  "ellipse",
  "arrow",
  "line",
  "freedraw",
  "text",
  "image",
  "eraser",
  "hand",
  "frame",
  "embeddable",
  "laser",
]);

const UNDO = "[data-testid=button-undo]";
const REDO = "[data-testid=button-redo]";
const BUTTONS: Record<string, string> = {
  zoomIn: ".zoom-in-button",
  zoomOut: ".zoom-out-button",
  resetZoom: ".reset-zoom-button",
  undo: UNDO,
  redo: REDO,
};

function isEnabled(selector: string) {
  const button = document.querySelector<HTMLButtonElement>(selector);
  return button !== null && !button.disabled;
}

/** Typing in a text element on the canvas or a field in the page (search, export file name). */
export function isEditingText() {
  const element = document.activeElement;
  if (element instanceof HTMLTextAreaElement) return true;
  if (element instanceof HTMLInputElement) return !["checkbox", "radio", "range", "button"].includes(element.type);
  return element instanceof HTMLElement && element.isContentEditable;
}

export function canvasUI(appState: AppState): CanvasUI {
  const { activeTool } = appState;
  // While typing, Edit ▸ Undo undoes the typing (runCommand), so it stays available.
  const editing = isEditingText();
  return {
    tool: activeTool.type === "custom" ? (activeTool.customType ?? "custom") : activeTool.type,
    locked: activeTool.locked,
    zoom: appState.zoom.value,
    canUndo: editing || isEnabled(UNDO),
    canRedo: editing || isEnabled(REDO),
    grid: appState.gridModeEnabled,
    snap: appState.objectsSnapModeEnabled,
    zen: appState.zenModeEnabled,
    viewMode: appState.viewModeEnabled,
    background: toOpaque(appState.viewBackgroundColor),
  };
}

/** Runs a command; false when it did not apply (unknown name, bad argument, nothing to act on). */
export function runCommand(api: ExcalidrawImperativeAPI, name: string, arg?: unknown): boolean {
  const appState = api.getAppState();
  // The menu, clicked while typing, undoes the typing as ⌘Z would, not the last change to the board.
  if ((name === "undo" || name === "redo") && isEditingText()) {
    return document.execCommand(name);
  }
  const button = BUTTONS[name];
  if (button) {
    if (!isEnabled(button)) return false;
    document.querySelector<HTMLButtonElement>(button)!.click();
    return true;
  }
  switch (name) {
    case "tool":
      if (typeof arg !== "string" || !TOOLS.has(arg)) return false;
      api.setActiveTool({ type: arg as ToolType });
      return true;
    // As Excalidraw's own lock button: unlocking goes back to selection. Locking sets the state directly,
    // since setActiveTool would run the image tool's file picker again.
    case "lock": {
      const { activeTool } = appState;
      if (activeTool.locked) {
        api.setActiveTool({ type: "selection", locked: false });
      } else {
        api.updateScene({ appState: { activeTool: { ...activeTool, locked: true } } });
      }
      return true;
    }
    case "zoomToFit": {
      const elements = api.getSceneElements();
      if (elements.length === 0) return false;
      api.scrollToContent(elements, { fitToContent: true, animate: true });
      return true;
    }
    case "export":
      // The dialog keeps the appState it opened with, so the opaque background color goes in together
      // with opening it; bridge.ts makes it transparent again when the dialog closes (background.ts).
      api.updateScene({
        appState: { openDialog: { name: "imageExport" }, viewBackgroundColor: toOpaque(appState.viewBackgroundColor) },
        captureUpdate: CaptureUpdateAction.NEVER,
      });
      return true;
    case "help":
      api.updateScene({ appState: { openDialog: { name: "help" } } });
      return true;
    case "library":
      api.toggleSidebar({ name: "default", tab: "library" });
      return true;
    case "search":
      api.toggleSidebar({ name: "default", tab: "search", force: true });
      return true;
    case "background":
      // View mode is read-only; Excalidraw's own background picker is not shown in it either.
      if (appState.viewModeEnabled) return false;
      if (typeof arg !== "string" || !/^#[0-9a-f]{6}$/i.test(arg)) return false;
      // Saved in the file, so it is an undo step like Excalidraw's own background picker.
      // Transparent in the scene, painted by the layer under the canvas (background.ts).
      api.updateScene({
        appState: { viewBackgroundColor: toTransparent(arg) },
        captureUpdate: CaptureUpdateAction.IMMEDIATELY,
      });
      return true;
    // Grid and object snapping exclude each other, as in Excalidraw's own toggles.
    case "grid":
      api.updateScene({ appState: { gridModeEnabled: !appState.gridModeEnabled, objectsSnapModeEnabled: false } });
      return true;
    case "snap":
      api.updateScene({
        appState: { objectsSnapModeEnabled: !appState.objectsSnapModeEnabled, gridModeEnabled: false },
      });
      return true;
    case "zen":
      api.updateScene({ appState: { zenModeEnabled: !appState.zenModeEnabled } });
      return true;
    case "viewMode":
      api.updateScene({ appState: { viewModeEnabled: !appState.viewModeEnabled } });
      return true;
    default:
      return false;
  }
}
