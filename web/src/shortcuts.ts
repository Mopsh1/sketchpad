// Shows the shortcuts in Excalidraw's context menu the way macOS menus do: "Cmd+Shift+L" becomes
// "⇧⌘L", with modifiers in the ⌃⌥⇧⌘ order.

const MODIFIERS: Record<string, string> = { Ctrl: "⌃", Option: "⌥", Alt: "⌥", Shift: "⇧", Cmd: "⌘" };
const ORDER = "⌃⌥⇧⌘";
const KEYS: Record<string, string> = { Delete: "⌫", Backspace: "⌫", Escape: "⎋", Enter: "↩", Tab: "⇥" };

/** Returns the text unchanged when it is not a shortcut in Excalidraw's notation. */
export function macShortcut(text: string): string {
  const parts = text.trim().split("+");
  const key = parts.pop();
  // "Cmd++" splits into empty parts; leave anything unusual alone.
  if (!key) return text;
  const symbols = parts.map((part) => MODIFIERS[part]);
  if (symbols.some((symbol) => symbol === undefined)) return text;
  symbols.sort((a, b) => ORDER.indexOf(a!) - ORDER.indexOf(b!));
  return symbols.join("") + (KEYS[key] ?? (key.length === 1 ? key.toUpperCase() : key));
}

function rewriteContextMenu() {
  for (const shortcut of document.querySelectorAll(".context-menu-item__shortcut")) {
    // Change the text node React rendered rather than replacing it, so React keeps its reference.
    const text = shortcut.firstChild;
    if (text?.nodeType === Node.TEXT_NODE && text.nodeValue) {
      const mac = macShortcut(text.nodeValue);
      if (mac !== text.nodeValue) text.nodeValue = mac;
    }
  }
}

/** The menu renders right after the contextmenu event; rewriting twice is harmless. */
export function showMacShortcuts() {
  document.addEventListener(
    "contextmenu",
    () => {
      window.setTimeout(rewriteContextMenu, 0);
      window.requestAnimationFrame(rewriteContextMenu);
    },
    true,
  );
}
