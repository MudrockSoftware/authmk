// Syntax highlighting at build time, with Shiki. Each token gets a light and
// a dark colour as CSS variables; app.css picks one for the theme in use.

import { createHighlighter } from "shiki";

const languages = ["elixir", "html", "http", "javascript", "json", "shellscript"] as const;

// Names used in the docs' code fences, for languages Shiki knows by another name.
const aliases: Record<string, (typeof languages)[number]> = {
  heex: "html",
  js: "javascript",
  sh: "shellscript",
  bash: "shellscript",
  shell: "shellscript"
};

const highlighter = await createHighlighter({
  themes: ["github-light", "github-dark"],
  langs: [...languages]
});

function language(name: string | undefined): string {
  const lang = (name ?? "").toLowerCase();
  if (lang in aliases) return aliases[lang];
  return (languages as readonly string[]).includes(lang) ? lang : "text";
}

/** Highlighted code as a <pre> element. */
export function highlight(code: string, lang?: string): string {
  return highlighter.codeToHtml(code, {
    lang: language(lang),
    themes: { light: "github-light", dark: "github-dark" },
    defaultColor: false
  });
}
