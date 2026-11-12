// What a docs page needs: the document, and the pages before and after it.

import { error } from "@sveltejs/kit";
import { githubUrl } from "#lib/site.ts";
import { docs } from "./content.ts";

export function loadDocPage(slug: string) {
  const position = docs.findIndex((doc) => doc.slug === slug);
  if (position === -1) error(404, "Page not found");
  const doc = docs[position];
  const link = (other: (typeof docs)[number] | undefined) => (other ? { title: other.title, path: other.path } : null);

  return {
    title: doc.title,
    html: doc.html,
    headings: doc.headings.filter((heading) => heading.depth >= 2),
    source: githubUrl(doc.file),
    previous: link(docs[position - 1]),
    next: link(docs[position + 1]),
  };
}
