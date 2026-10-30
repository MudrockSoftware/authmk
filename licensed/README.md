# Licensed features

The admin dashboard (`Authmk.Dashboard`) and its analytics live here,
separate from the MIT-licensed library in `lib/`. See `LICENSE.md`.

- `lib/`: the Elixir side, a Plug that serves the app and its JSON API
  (`Authmk.Dashboard.API`). Tests: `test/` (run with `mix test` like the rest).
- `dashboard/`: the app, in SvelteKit (Svelte 5, Tailwind 4, daisyUI 5 with
  Mudrock's themes, Lucide icons, Chart.js). `mix compile` builds it
  with bun into `../priv/licensed/dashboard/` (not in git). The Hex package
  ships that build, so apps using authmk never need bun or Node.
- In development and tests no licence key is needed. Elsewhere,
  `AUTHMK_LICENCE_KEY` must hold a valid key (`Authmk.License`): without one
  the dashboard answers every request (page, files, API) with a 403. Keys will be
  checked by the licence server at https://license.mudrock.dev; until it
  exists, `Authmk.License` checks their shape only.

## Working on the dashboard

With bun (see `dashboard/mise.toml`):

```sh
cd licensed/dashboard
bun install
bun run check    # types and Svelte
bun run build    # what `mix compile` runs: writes ../../priv/licensed/dashboard
```

To work on it live, run the example Phoenix app on port 4000 (`cd
examples/phoenix_app && mix phx.server`), sign in there as an admin, then
`bun run dev` here: Vite proxies `/api` to the app's dashboard API. Changes
(POST) are refused from Vite's origin; try them on the built dashboard.
