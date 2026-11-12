import { json } from "@sveltejs/kit";
import { docs, exampleApps } from "#lib/server/content.ts";
import { moduleUrl, publicModules } from "#lib/server/modules.ts";
import type { SearchEntry } from "#lib/search.ts";

export const prerender = true;

export function GET() {
  const entries: SearchEntry[] = [
    ...docs.flatMap((doc) =>
      doc.sections.map((section, position) => ({
        id: `docs:${doc.path}:${position}`,
        kind: "Docs" as const,
        title: doc.title,
        section: section.id ? section.heading : "",
        url: section.id ? `${doc.path}#${section.id}` : doc.path,
        text: section.text
      }))
    ),
    ...exampleApps.flatMap((app) =>
      app.files.map((file) => ({
        id: `example:${file.path}`,
        kind: "Example" as const,
        title: `${app.name}: ${file.title}`,
        section: "",
        url: `examples#${file.id}`,
        text: `${file.description} ${file.path}`
      }))
    ),
    ...publicModules.map((module) => ({
      id: `api:${module.name}`,
      kind: "API" as const,
      title: module.name,
      section: "",
      url: moduleUrl(module.name),
      text: module.summary
    }))
  ];
  return json(entries);
}
