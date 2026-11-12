// authmk's public modules, read from the source, so the docs can link a
// module's name to its page on HexDocs and search can find it. A module with
// `@moduledoc false` isn't on HexDocs, so it's left out.

import { listRepositoryFiles, readRepositoryFile } from "./repository.ts";
import { site } from "#lib/site.ts";

export type PublicModule = { name: string; summary: string };

const definition = /^\s*defmodule\s+(Authmk[\w.]*)\s+do\b/gm;
const moduledoc = /@moduledoc\s+(false|(?:~S)?"""\s*\n\s*([^\n]*)|"([^"\n]*)")/;

/** The modules a file defines, with each one's `@moduledoc`, if it has one. */
function modulesIn(source: string): PublicModule[] {
  const starts = [...source.matchAll(definition)];
  return starts.flatMap((match, position) => {
    const body = source.slice(match.index, starts[position + 1]?.index ?? source.length);
    const doc = moduledoc.exec(body);
    if (doc?.[1] === "false") return [];
    return [{ name: match[1], summary: (doc?.[2] ?? doc?.[3] ?? "").trim() }];
  });
}

function read(): PublicModule[] {
  const files = [...listRepositoryFiles("lib"), ...listRepositoryFiles("licensed/lib")].filter((file) =>
    file.endsWith(".ex"),
  );
  return files
    .flatMap((file) => modulesIn(readRepositoryFile(file)))
    .sort((a, b) => a.name.localeCompare(b.name));
}

export const publicModules: PublicModule[] = read();

const names = new Set(publicModules.map((module) => module.name));

export function moduleUrl(name: string): string {
  return `${site.hexdocs}/${name}.html`;
}

/**
 * The HexDocs page for a reference written as ExDoc writes them:
 * `Authmk.Plug`, `Authmk.Payments.allowed?/4` or `c:Authmk.Plugin.init/1`.
 * Null when it isn't a public module of authmk.
 */
export function referenceUrl(reference: string): string | null {
  const match = /^(?:([ct]):)?(Authmk(?:\.[A-Z]\w*)*)(?:\.([a-z_]\w*[?!]?)\/(\d+))?$/.exec(reference);
  if (!match) return null;
  const [, kind, module, fun, arity] = match;
  if (!names.has(module)) return null;
  if (!fun) return kind ? null : moduleUrl(module);
  return `${moduleUrl(module)}#${kind ? `${kind}:` : ""}${fun}/${arity}`;
}
