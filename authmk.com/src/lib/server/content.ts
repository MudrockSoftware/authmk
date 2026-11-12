// Everything the site shows from the repository, read once per build.

import type { Path } from "$app/types";
import { docGroups, docPath, docSources, type DocSource } from "#lib/docs.ts";
import { renderMarkdown, type RenderedMarkdown } from "./markdown.ts";
import { highlight } from "./highlight.ts";
import { listRepositoryFiles, readRepositoryFile } from "./repository.ts";

export type Doc = DocSource & RenderedMarkdown & { path: Path };

function loadDoc(source: DocSource): Doc {
  const rendered = renderMarkdown(readRepositoryFile(source.file), source.file);
  return { ...source, ...rendered, title: source.title ?? rendered.title, path: docPath(source.slug) };
}

// A new guide must be given a place in src/lib/docs.ts, or it would be
// missing from the site without anyone noticing.
const unlisted = listRepositoryFiles("guides").filter(
  (file) => file.endsWith(".md") && !docSources.some((source) => source.file === file)
);
if (unlisted.length > 0) {
  throw new Error(`Add these guides to website/src/lib/docs.ts: ${unlisted.join(", ")}`);
}

export const docs: Doc[] = docSources.map(loadDoc);

export function findDoc(slug: string): Doc | undefined {
  return docs.find((doc) => doc.slug === slug);
}

/** The sidebar: each group's pages, with their titles. */
export const navigation = docGroups.map((group) => ({
  title: group.title,
  pages: group.docs.map((source) => ({ title: findDoc(source.slug)!.title, path: docPath(source.slug) }))
}));

export type ExampleFile = { id: string; path: string; title: string; description: string; html: string; lines: number };
export type ExampleApp = { id: string; name: string; summary: string; path: string; files: ExampleFile[] };

function exampleFile(path: string, title: string, description: string): Omit<ExampleFile, "id"> {
  const code = readRepositoryFile(path).trimEnd();
  const lang = path.endsWith(".heex") ? "heex" : "elixir";
  return { path, title, description, html: highlight(code, lang), lines: code.split("\n").length };
}

/** Gives each file an anchor on /examples, such as "phoenix-router". */
function withAnchors(app: Omit<ExampleApp, "files"> & { files: Omit<ExampleFile, "id">[] }): ExampleApp {
  const files = app.files.map((file) => ({ ...file, id: `${app.id}-${file.title.toLowerCase().replaceAll(" ", "-")}` }));
  return { ...app, files };
}

// The example apps in examples/, shown file by file. These are the real files
// their tests run against, so what the site shows always works.
export const exampleApps: ExampleApp[] = [
  withAnchors({
    id: "phoenix",
    name: "Phoenix app",
    summary: "Phoenix 1.8 with LiveView and Ecto on SQLite: authmk's components, LiveView sessions and the admin dashboard.",
    path: "examples/phoenix_app/",
    files: [
      exampleFile(
        "examples/phoenix_app/lib/phoenix_app/auth.ex",
        "Auth module",
        "Every plugin the app uses, with its options and the callbacks that send emails and codes."
      ),
      exampleFile(
        "examples/phoenix_app/lib/phoenix_app_web/router.ex",
        "Router",
        "Mounts authmk and the dashboard, loads the signed-in user, and guards LiveView sessions."
      ),
      exampleFile(
        "examples/phoenix_app/lib/phoenix_app_web/live/sign_in_live.ex",
        "Sign-in page",
        "A LiveView built from authmk's components: a password form and a passkey button."
      ),
      exampleFile(
        "examples/phoenix_app/lib/phoenix_app_web/live/settings_live.ex",
        "Account settings",
        "A signed-in LiveView: account settings, sessions and the organization switcher, from authmk's components."
      ),
      exampleFile(
        "examples/phoenix_app/test/phoenix_app_web/auth_test.exs",
        "Tests",
        "Signing up, signing out and refused cross-site requests, tested through the app."
      )
    ]
  }),
  withAnchors({
    id: "plug",
    name: "Plug app",
    summary: "Plain Plug and Bandit with Ecto on SQLite, for apps without Phoenix.",
    path: "examples/plug_app/",
    files: [
      exampleFile(
        "examples/plug_app/lib/plug_app/auth.ex",
        "Auth module",
        "The plugins, their options and callbacks, in one module."
      ),
      exampleFile(
        "examples/plug_app/lib/plug_app/router.ex",
        "Router",
        "Forwards /auth to authmk and protects the app's own routes with its plugs."
      ),
      exampleFile(
        "examples/plug_app/lib/plug_app/application.ex",
        "Application",
        "Starts the auth module after the repo."
      ),
      exampleFile(
        "examples/plug_app/test/plug_app/auth_test.exs",
        "Tests",
        "Full flows through the router with Plug.Test."
      )
    ]
  })
];
