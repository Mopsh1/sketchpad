import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    // Excalidraw alone is a few MB; the bundle is loaded from disk, so chunk size doesn't matter.
    chunkSizeWarningLimit: 8000,
  },
});
