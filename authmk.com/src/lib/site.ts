// Facts about authmk used across the site.

export const site = {
  name: "authmk",
  url: "https://authmk.com",
  description:
    "An extensible, plugin-based authentication framework for Elixir, for Phoenix and Plug apps.",
  version: "1.2",
  github: "https://github.com/MudrockSoftware/authmk",
  hexdocs: "https://hexdocs.pm/authmk",
  hex: "https://hex.pm/packages/authmk",
  licence: "https://license.mudrock.dev",
  mudrock: "https://mudrock.dev",
  mudrockName: "Mudrock Software",
  mudrockGithub: "https://github.com/MudrockSoftware",
  legalName: "MUDROCK SOFTWARE LTD",
  /** The picture link previews show (static/og-image.png), 1200 by 630. */
  socialImage: "/og-image.png"
} as const;

/** Mudrock as schema.org data. The @id matches mudrock.dev's own, so search engines join the two. */
export const mudrockOrganization = {
  "@type": "Organization",
  "@id": `${site.mudrock}/#organization`,
  name: site.mudrockName,
  legalName: site.legalName,
  url: `${site.mudrock}/`,
  sameAs: [site.mudrockGithub]
} as const;

/** A link to a file or directory in the repository on GitHub. */
export function githubUrl(path: string): string {
  const kind = path.endsWith("/") ? "tree" : "blob";
  return `${site.github}/${kind}/main/${path.replace(/\/$/, "")}`;
}
