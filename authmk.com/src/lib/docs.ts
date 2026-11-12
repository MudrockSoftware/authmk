import type { Path } from "$app/types";

// Which documents the site shows, in what order, and where each comes from.
// Titles come from each file's first heading. The guides keep the order of
// the HexDocs extras in mix.exs.

export type DocSource = {
  /** The page's path under /docs; "" is /docs itself. */
  slug: string;
  /** The Markdown file, from the repository's root. */
  file: string;
  /** Replaces the file's own first heading, when that doesn't suit a page. */
  title?: string;
};

export type DocGroup = { title: string; docs: DocSource[] };

const guide = (name: string): DocSource => ({ slug: name, file: `guides/${name}.md` });

export const docGroups: DocGroup[] = [
  {
    title: "Start here",
    docs: [{ slug: "", file: "README.md", title: "Overview" }]
  },
  {
    title: "Guides",
    docs: [
      "email-password-and-sessions",
      "social-sign-in",
      "sign-in-methods",
      "organizations-and-access-control",
      "phoenix-and-liveview",
      "api-clients",
      "payments",
      "oauth-provider",
      "enterprise-sso-and-scim",
      "browser-extensions",
      "testing",
      "writing-plugins"
    ].map(guide)
  },
  {
    title: "In production",
    docs: ["security", "deployment", "cookies-and-domains", "performance", "stability", "errors"].map(guide)
  },
  {
    title: "Migrating",
    docs: ["migrating-from-phx-gen-auth", "migrating-from-pow", "migrating-from-ash-authentication"].map(guide)
  },
  {
    title: "Project",
    docs: [
      { slug: "changelog", file: "CHANGELOG.md" },
      { slug: "security-policy", file: "SECURITY.md" }
    ]
  }
];

export const docSources: DocSource[] = docGroups.flatMap((group) => group.docs);

/** The page's path as resolve() takes it, without the leading slash: "docs/security". */
export function docPath(slug: string): Path {
  return slug === "" ? "docs" : `docs/${slug}`;
}
