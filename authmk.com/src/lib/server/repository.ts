// Reads files from the authmk repository the site is built in. The site's
// build runs from website/, so the repository is its parent directory.

import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(process.cwd(), "..");

export function readRepositoryFile(path: string): string {
  return readFileSync(join(root, path), "utf8");
}

/** Every file under a directory of the repository, as repository paths. */
export function listRepositoryFiles(directory: string): string[] {
  return readdirSync(join(root, directory), { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => join(entry.parentPath, entry.name).slice(root.length + 1));
}
