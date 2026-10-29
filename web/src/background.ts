// The canvas background: its color, and an optional dot or square pattern under the drawing.
//
// Excalidraw 0.18.1 draws only a plain color (its grid also snaps, and has no dots). So while a board
// is shown, its scene color is kept transparent — "#rrggbb00", which Excalidraw clears the canvas
// to — and the layer under the canvas (.sketchpad-pattern, App.tsx) paints the color and the pattern,
// following the canvas's scroll and zoom. What is saved, reported and exported is the opaque color:
// bridge.ts converts at load and save, and while the export dialog is open the scene gets the opaque
// color back (with no undo step), since Excalidraw exports the scene's own color.
import type { AppState } from "@excalidraw/excalidraw/types";

export type Pattern = "none" | "dots" | "grid";

// Spacing in scene units at 100%, Excalidraw's own grid size.
const GAP = 20;
// Zoomed out, the spacing doubles until it is at least this many screen pixels.
const MIN_GAP = 12;
const DEFAULT_COLOR = "#ffffff";

let pattern: Pattern = "none";
let last: Pick<AppState, "scrollX" | "scrollY" | "zoom" | "viewBackgroundColor"> | null = null;

/** "#rrggbb" → "#rrggbb00"; other colors (named, already transparent) stay as they are, opaque on canvas. */
export function toTransparent(color: string) {
  return /^#[0-9a-f]{6}$/i.test(color) ? `${color}00` : color;
}

/** "#rrggbb00" → "#rrggbb", the color the file keeps. */
export function toOpaque(color: string) {
  return /^#[0-9a-f]{6}00$/i.test(color) ? color.slice(0, 7) : color;
}

export function isTransparent(color: string) {
  return /^#[0-9a-f]{6}00$/i.test(color);
}

export function setPattern(next: string) {
  pattern = next === "dots" || next === "grid" ? next : "none";
  if (last) paint(last);
}

/** Repaints the layer for the canvas's current color, scroll and zoom; called from onChange. */
export function paint(appState: Pick<AppState, "scrollX" | "scrollY" | "zoom" | "viewBackgroundColor">) {
  last = appState;
  const layer = document.getElementById("sketchpad-pattern");
  if (!layer) return;
  const color = toOpaque(appState.viewBackgroundColor);
  layer.style.backgroundColor = /^#[0-9a-f]{6}$/i.test(color) ? color : DEFAULT_COLOR;
  if (pattern === "none") {
    layer.style.backgroundImage = "none";
    return;
  }
  const zoom = appState.zoom.value;
  let step = GAP;
  while (step * zoom < MIN_GAP) step *= 2;
  const gap = step * zoom;
  // The scene origin is at (scrollX, scrollY) × zoom in the viewport.
  const x = ((appState.scrollX * zoom) % gap + gap) % gap;
  const y = ((appState.scrollY * zoom) % gap + gap) % gap;
  layer.style.backgroundImage =
    pattern === "dots"
      ? "radial-gradient(circle at 1px 1px, var(--sketchpad-dot) 1.1px, transparent 1.6px)"
      : "linear-gradient(to right, var(--sketchpad-line) 1px, transparent 1px)," +
        "linear-gradient(to bottom, var(--sketchpad-line) 1px, transparent 1px)";
  layer.style.backgroundSize = `${gap}px ${gap}px`;
  // Dots are drawn 1px into each tile, so shift them back onto the grid points.
  const shift = pattern === "dots" ? 1 : 0;
  layer.style.backgroundPosition = `${x - shift}px ${y - shift}px`;
}
