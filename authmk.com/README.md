# authmk.com

authmk's website: the introduction, the docs, the example apps and search.
A static SvelteKit site (bun, Tailwind CSS, daisyUI) in Mudrock's theme.

The docs aren't written here. At build time the site reads them from the
repository around it:

- `README.md` is the overview at `/docs`, and `guides/*.md`, `CHANGELOG.md`
  and `SECURITY.md` are the other pages. Their order and groups are in
  `src/lib/docs.ts`; a guide missing from there fails the build.
- `examples/` gives the code on `/examples` (`src/lib/server/content.ts`).
- `lib/` and `licensed/lib` give the module names that link to HexDocs and
  appear in search.

Code is highlighted with Shiki when the site is built, and search runs in the
browser with MiniSearch over `/search.json`, built with the pages.

## Developing

```sh
bun install
bun run dev       # http://localhost:5173
bun run check     # types
bun run lint
bun run build     # the site in build/; fails on links to missing pages or anchors
bun run preview
```

## Deploying

`build/` is plain static files. `wrangler.jsonc` serves it on Cloudflare
Workers static assets, as for mudrock.dev, with `static/_headers` for
response headers and `build/404.html` for unknown paths.
