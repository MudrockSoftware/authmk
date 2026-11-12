import { mdsvex } from "mdsvex";
import tailwindcss from "@tailwindcss/vite";
import adapter from "@sveltejs/adapter-static";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

// authmk.com: the introduction and the docs, as a static site. The docs
// pages are prerendered from the repository around this directory
// (README.md, guides/, CHANGELOG.md, SECURITY.md and examples/), so the site
// and HexDocs say the same.
export default defineConfig({
  plugins: [
    tailwindcss(),
    sveltekit({
      compilerOptions: {
        // Force runes mode for the project, except for libraries. Can be removed in svelte 6.
        runes: ({ filename }) =>
          filename.split(/[/\\]/).includes("node_modules") ? undefined : true,
      },
      // Unknown paths get 404.html (see wrangler.jsonc).
      adapter: adapter({ fallback: "404.html", strict: true }),
      // Links from the site's root, so 404.html works at any depth and the
      // current page can be found by comparing paths.
      paths: { relative: false },
      prerender: {
        // Fail the build on a link to a page or an anchor that doesn't exist.
        handleHttpError: "fail",
        handleMissingId: "fail",
      },
      csp: {
        mode: "hash",
        directives: {
          "default-src": ["self"],
          "script-src": ["self"],
          // Highlighted code sets its colours in style attributes.
          "style-src": ["self", "unsafe-inline"],
          "img-src": ["self", "data:"],
          "font-src": ["self"],
          "connect-src": ["self"],
          "object-src": ["none"],
          "base-uri": ["self"],
          "form-action": ["self"],
        },
      },
      preprocess: [mdsvex({ extensions: [".svx", ".md"] })],
      extensions: [".svelte", ".svx", ".md"],
    }),
  ],
  server: {
    // The docs are read from the repository around this directory.
    fs: { allow: [".."] },
  },
});
