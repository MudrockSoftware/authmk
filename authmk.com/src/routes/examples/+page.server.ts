import { exampleApps } from "#lib/server/content.ts";

export function load() {
  return { apps: exampleApps };
}
