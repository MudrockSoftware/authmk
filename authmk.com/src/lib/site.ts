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
  legalName: "MUDROCK SOFTWARE LTD"
} as const;

/** A link to a file or directory in the repository on GitHub. */
export function githubUrl(path: string): string {
  const kind = path.endsWith("/") ? "tree" : "blob";
  return `${site.github}/${kind}/main/${path.replace(/\/$/, "")}`;
}
