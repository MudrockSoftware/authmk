import { MediaQuery } from "svelte/reactivity";
import { browser } from "$app/env";

// Light or dark theme. Until the visitor picks one we follow their system
// setting (daisyUI's `prefersdark`) and store nothing. Keep THEME_KEY in sync
// with static/theme.js, which applies it before first paint.
const THEME_KEY = "authmk_theme";

type Choice = "light" | "dark";

const themes: Record<Choice, string> = { light: "mudrock", dark: "mudrock-dark" };

const prefersDark = new MediaQuery("(prefers-color-scheme: dark)");

function read(): Choice | null {
  if (!browser) return null;
  const value = localStorage.getItem(THEME_KEY);
  return value === "light" || value === "dark" ? value : null;
}

let choice = $state<Choice | null>(read());

export const theme = {
  get dark() {
    return choice ? choice === "dark" : prefersDark.current;
  },
  toggle() {
    choice = theme.dark ? "light" : "dark";
    localStorage.setItem(THEME_KEY, choice);
    document.documentElement.dataset.theme = themes[choice];
  }
};
