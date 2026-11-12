import { docs } from "#lib/server/content.ts";
import { loadDocPage } from "#lib/server/doc-page.ts";
import type { EntryGenerator, PageServerLoad } from "./$types";

export const entries: EntryGenerator = () => docs.filter((doc) => doc.slug !== "").map((doc) => ({ slug: doc.slug }));

export const load: PageServerLoad = ({ params }) => loadDocPage(params.slug);
