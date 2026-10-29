import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@excalidraw/excalidraw/index.css";
import "./index.css";
import "./native.css";
import App from "./App";
import { showMacShortcuts } from "./shortcuts";

showMacShortcuts();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
