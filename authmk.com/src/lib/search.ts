// The search index: one entry per section of a docs page, per example file
// and per public module. Built by src/routes/search.json, read by Search.svelte.

export type SearchEntry = {
  id: string;
  kind: "Docs" | "Example" | "API";
  /** The page, file or module. */
  title: string;
  /** The heading inside the page, if any. */
  section: string;
  /** A path on this site as resolve() takes it ("docs/security#csrf"), or a HexDocs URL for "API". */
  url: string;
  text: string;
};
