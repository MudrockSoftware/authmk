// Applies the visitor's saved theme before the page paints. Loaded from a
// file rather than inline, so the Content-Security-Policy needs no exception.
// Keep the key in sync with src/lib/theme.svelte.ts.
try {
  const theme = localStorage.getItem("authmk_theme");
  if (theme === "light" || theme === "dark") {
    document.documentElement.dataset.theme = theme === "dark" ? "mudrock-dark" : "mudrock";
  }
} catch {
  // Storage can be blocked; the system setting applies then.
}
