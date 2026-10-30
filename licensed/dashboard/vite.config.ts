import tailwindcss from "@tailwindcss/vite";
import adapter from "@sveltejs/adapter-static";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

// Built into authmk's priv/, where Authmk.Dashboard serves it from whatever
// path the app mounts it at: hash routing and relative asset links, so one
// build works anywhere. During `bun dev`, the API comes from the example
// Phoenix app (see README.md).
export default defineConfig({
  plugins: [
    tailwindcss(),
    sveltekit({
      compilerOptions: { runes: true },
      adapter: adapter({
        pages: "../../priv/licensed/dashboard",
        assets: "../../priv/licensed/dashboard",
        fallback: "index.html",
        strict: true
      }),
      paths: { relative: true },
      router: { type: "hash" },
      csp: {
        mode: "hash",
        directives: {
          "default-src": ["self"],
          "script-src": ["self"],
          "style-src": ["self", "unsafe-inline"],
          "img-src": ["self", "data:", "https:"],
          "font-src": ["self"],
          "connect-src": ["self"],
          "object-src": ["none"],
          "base-uri": ["self"],
          "form-action": ["self"]
        }
      }
    })
  ],
  server: {
    proxy: {
      "/api": { target: "http://localhost:4000/admin/auth", changeOrigin: false }
    }
  }
});
