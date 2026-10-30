// Light, dark, or the system's choice; remembered on this browser.

type Choice = "system" | "light" | "dark";

const key = "authmk-dashboard-theme";

function read(): Choice {
  const saved = typeof localStorage === "undefined" ? null : localStorage.getItem(key);
  return saved === "light" || saved === "dark" ? saved : "system";
}

function apply(choice: Choice) {
  const root = document.documentElement;
  if (choice === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", choice === "dark" ? "mudrock-dark" : "mudrock");
}

class Theme {
  choice = $state<Choice>(read());
  // Bumped on every change, so charts redraw with the new colours.
  version = $state(0);

  constructor() {
    if (typeof window !== "undefined") {
      apply(this.choice);
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.version++);
    }
  }

  get dark(): boolean {
    if (this.choice === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches;
    return this.choice === "dark";
  }

  toggle() {
    this.choice = this.dark ? "light" : "dark";
    localStorage.setItem(key, this.choice);
    apply(this.choice);
    this.version++;
  }
}

export const theme = new Theme();
