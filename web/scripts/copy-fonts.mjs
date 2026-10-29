// Copies Excalidraw's font files into public/fonts so the app works offline.
// Without them Excalidraw falls back to downloading fonts from esm.sh.
import { cpSync, rmSync } from "node:fs";

const from = new URL("../node_modules/@excalidraw/excalidraw/dist/prod/fonts", import.meta.url);
const to = new URL("../public/fonts", import.meta.url);

rmSync(to, { recursive: true, force: true });
cpSync(from, to, { recursive: true });
