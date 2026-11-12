// Turns the repository's Markdown (README, guides, changelog) into HTML for
// the docs, with what the page and the search need: headings for the
// table of contents, and plain-text sections for the search index.
//
// The Markdown is authmk's own, from the repository, so its HTML is trusted.

import { Marked, type Token, type Tokens } from "marked";
import { posix } from "node:path";
import { docPath, docSources } from "#lib/docs.ts";
import { githubUrl, site } from "#lib/site.ts";
import { highlight } from "./highlight.ts";
import { referenceUrl } from "./modules.ts";

export type Heading = { depth: number; id: string; text: string };
export type Section = { id: string; heading: string; text: string };
export type RenderedMarkdown = {
  title: string;
  html: string;
  headings: Heading[];
  sections: Section[];
};

type IdentifiedHeading = Tokens.Heading & { id?: string };

export function escapeHtml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Anchors as GitHub and ExDoc make them, so links between guides keep working. */
function createSlugger(): (text: string) => string {
  const seen = new Map<string, number>();
  return (text) => {
    const base = text
      .toLowerCase()
      .trim()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s/g, "-");
    const count = seen.get(base) ?? 0;
    seen.set(base, count + 1);
    return count === 0 ? base : `${base}-${count}`;
  };
}

/** Where a link in a repository file should go on the site. */
function siteHref(href: string, file: string): string {
  if (/^[a-z]+:/i.test(href) || href.startsWith("#") || href.startsWith("//")) return href;

  const [path, anchor] = href.split("#", 2);
  const target = posix.normalize(posix.join(posix.dirname(file), path)) + (path.endsWith("/") ? "/" : "");
  const doc = docSources.find((source) => source.file === target);
  const base = doc ? `/${docPath(doc.slug)}` : githubUrl(target);
  return anchor ? `${base}#${anchor}` : base;
}

/** Plain text of a token's Markdown, for the search index. */
function plainText(markdown: string): string {
  return markdown
    .replace(/^```.*$/gm, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/<(https?:[^>]+)>/g, "$1")
    .replace(/[`*|>#]/g, " ")
    .replace(/^-{3,}$/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}

function headingText(token: Tokens.Heading): string {
  return plainText(token.text);
}

function sectionsOf(tokens: Token[], title: string): Section[] {
  const sections: Section[] = [{ id: "", heading: title, text: "" }];
  for (const token of tokens) {
    if (token.type === "heading" && token.depth >= 2 && token.depth <= 3) {
      sections.push({ id: (token as IdentifiedHeading).id ?? "", heading: headingText(token as Tokens.Heading), text: "" });
    } else if (token.type !== "heading" && token.type !== "space") {
      const section = sections[sections.length - 1];
      section.text = `${section.text} ${plainText(token.raw)}`.trim();
    }
  }
  return sections.filter((section) => section.text !== "" || section.id !== "");
}

export function renderMarkdown(source: string, file: string): RenderedMarkdown {
  const slug = createSlugger();
  const marked = new Marked({ gfm: true });
  const lexed = marked.lexer(source);

  // The page shows the title itself, from the first heading.
  const titleIndex = lexed.findIndex((token) => token.type === "heading" && token.depth === 1);
  const title = titleIndex === -1 ? "" : headingText(lexed[titleIndex] as Tokens.Heading);
  // The README links to this site; on this site, that line has no use.
  const isSiteLink = (token: Token) => token.type === "paragraph" && token.raw.trim() === `Website: <${site.url}>`;
  const kept = lexed.filter((token, index) => index !== titleIndex && !isSiteLink(token));
  const tokens = Object.assign(kept, { links: lexed.links });

  const headings: Heading[] = [];
  for (const token of tokens) {
    if (token.type === "heading") {
      const heading = token as IdentifiedHeading;
      heading.id = slug(headingText(heading));
      if (heading.depth <= 3) headings.push({ depth: heading.depth, id: heading.id, text: headingText(heading) });
    }
  }

  marked.use({
    renderer: {
      heading(token) {
        const id = (token as IdentifiedHeading).id ?? slug(headingText(token));
        const content = this.parser.parseInline(token.tokens);
        const anchor = `<a class="anchor" href="#${escapeHtml(id)}" aria-label="Link to this section">#</a>`;
        return `<h${token.depth} id="${escapeHtml(id)}">${content}${anchor}</h${token.depth}>\n`;
      },
      code({ text, lang }) {
        return `<div class="code-block">${highlight(text, lang)}<button type="button" class="copy-code" data-copy-code>Copy</button></div>\n`;
      },
      codespan({ text }) {
        const display = text.replace(/^[ct]:/, "");
        const url = referenceUrl(text);
        const code = `<code>${escapeHtml(display)}</code>`;
        return url ? `<a href="${escapeHtml(url)}" rel="external">${code}</a>` : code;
      },
      link({ href, title, tokens: children }) {
        const target = siteHref(href, file);
        const external = /^https?:/.test(target) ? ' rel="external"' : "";
        const titleAttribute = title ? ` title="${escapeHtml(title)}"` : "";
        return `<a href="${escapeHtml(target)}"${titleAttribute}${external}>${this.parser.parseInline(children)}</a>`;
      }
    }
  });

  // Wide tables scroll inside the page instead of widening it.
  const html = marked
    .parser(tokens)
    .replaceAll("<table>", '<div class="table-wrap"><table>')
    .replaceAll("</table>", "</table></div>");

  return {
    title,
    html,
    headings,
    sections: sectionsOf(tokens, title)
  };
}
