import tailwindcss from "@tailwindcss/vite";
import adapter from "@sveltejs/adapter-static";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

// The pages authmk shows people itself (like the sign-in error page),
// built into priv/pages. authmk serves them under its mount path, filling
// in each page's data: hash routing and relative links, so one build works
// wherever the app mounts authmk.
export default defineConfig({
  plugins: [
    tailwindcss(),
    sveltekit({
      compilerOptions: { runes: true },
      adapter: adapter({ pages: "../../priv/pages", assets: "../../priv/pages", fallback: "index.html", strict: true }),
      paths: { relative: true },
      router: { type: "hash" },
      csp: {
        mode: "hash",
        directives: {
          "default-src": ["self"],
          "script-src": ["self"],
          "style-src": ["self", "unsafe-inline"],
          "img-src": ["self", "data:"],
          "font-src": ["self"],
          "connect-src": ["self"],
          "object-src": ["none"],
          "base-uri": ["self"],
          "form-action": ["self"]
        }
      }
    })
  ]
});
