import { useEffect, useState, useSyncExternalStore } from "react";
import { Excalidraw, MainMenu, THEME } from "@excalidraw/excalidraw";
import type { ExcalidrawInitialDataState } from "@excalidraw/excalidraw/types";
import { attach, firstScene, linkOpened, onSceneReload, sceneChanged } from "./bridge";

const UI_OPTIONS = {
  canvasActions: {
    // Opening and saving belong to the native document window (⌘O, ⌘S), not Excalidraw's file dialogs.
    loadScene: false,
    saveToActiveFile: false,
    export: false as const,
  },
};

const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

function subscribeToColorScheme(onChange: () => void) {
  darkQuery.addEventListener("change", onChange);
  return () => darkQuery.removeEventListener("change", onChange);
}

type Board = { key: number; initialData: Promise<ExcalidrawInitialDataState | null> | ExcalidrawInitialDataState };

export default function App() {
  const dark = useSyncExternalStore(subscribeToColorScheme, () => darkQuery.matches);
  // A new key remounts Excalidraw, the only way to hand it a whole new scene (see bridge.ts).
  const [board, setBoard] = useState<Board>({ key: 0, initialData: firstScene });
  useEffect(() => onSceneReload((scene) => setBoard((b) => ({ key: b.key + 1, initialData: scene }))), []);
  return (
    <div className="sketchpad-board">
      {/* The background color and pattern under the transparent canvas (background.ts). */}
      <div id="sketchpad-pattern" className="sketchpad-pattern" />
      <Excalidraw
        key={board.key}
        initialData={board.initialData}
        excalidrawAPI={attach}
        onChange={sceneChanged}
        onLinkOpen={linkOpened}
        langCode="zh-TW"
        theme={dark ? THEME.DARK : THEME.LIGHT}
        UIOptions={UI_OPTIONS}
      >
        {/* Empty: its items are in the menu bar and native.css hides the trigger. Without it Excalidraw
            would fall back to its default menu, social links included. */}
        <MainMenu />
      </Excalidraw>
    </div>
  );
}
