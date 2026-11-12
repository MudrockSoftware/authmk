<!--
  Search across the docs, the example apps and the API, in the browser. The
  index (/search.json) and MiniSearch load the first time the dialog opens.
  Opens with Ctrl+K, ⌘K or "/".
-->
<script lang="ts">
  import type MiniSearch from "minisearch";
  import type { SearchResult } from "minisearch";
  import type { PathnameWithSearchOrHash } from "$app/types";
  import { afterNavigate } from "$app/navigation";
  import { resolve } from "$app/paths";
  import SearchIcon from "@lucide/svelte/icons/search";
  import X from "@lucide/svelte/icons/x";
  import type { SearchEntry } from "#lib/search.ts";
  import { searchDialog } from "#lib/search-dialog.svelte.ts";

  type Result = SearchResult & SearchEntry;

  let dialog: HTMLDialogElement;
  let input = $state<HTMLInputElement>();
  let query = $state("");
  let index = $state.raw<MiniSearch<SearchEntry> | null>(null);
  let failed = $state(false);
  let active = $state(0);

  const results = $derived(
    index && query.trim() ? (index.search(query.trim()) as Result[]).slice(0, 12) : []
  );
  const terms = $derived(query.trim().toLowerCase().split(/\s+/).filter(Boolean));

  $effect(() => {
    void results;
    active = 0;
  });

  $effect(() => {
    if (searchDialog.open && !dialog.open) {
      dialog.showModal();
      input?.focus();
      load();
    } else if (!searchDialog.open && dialog.open) {
      dialog.close();
    }
  });

  afterNavigate(() => (searchDialog.open = false));

  async function load() {
    if (index) return;
    failed = false;
    try {
      const [{ default: MiniSearch }, response] = await Promise.all([import("minisearch"), fetch("/search.json")]);
      if (!response.ok) throw new Error(`The search index answered ${response.status}.`);
      const entries: SearchEntry[] = await response.json();
      const search = new MiniSearch<SearchEntry>({
        fields: ["title", "section", "text"],
        storeFields: ["kind", "title", "section", "url", "text"],
        searchOptions: { boost: { section: 3, title: 2 }, prefix: true, fuzzy: 0.2, combineWith: "AND" }
      });
      search.addAll(entries);
      index = search;
    } catch {
      failed = true;
    }
  }

  /** A piece of the entry's text around the first word searched for. */
  function snippet(text: string): string {
    const lower = text.toLowerCase();
    const at = Math.min(...terms.map((term) => lower.indexOf(term)).filter((position) => position >= 0));
    if (!Number.isFinite(at)) return text.slice(0, 160);
    const start = Math.max(0, at - 60);
    return `${start > 0 ? "…" : ""}${text.slice(start, start + 180)}…`;
  }

  /** The snippet in parts, with the words searched for marked. */
  function parts(text: string): { text: string; match: boolean }[] {
    if (terms.length === 0) return [{ text, match: false }];
    const escaped = terms.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
    const pattern = new RegExp(`(${escaped.join("|")})`, "gi");
    return text
      .split(pattern)
      .filter(Boolean)
      .map((part) => ({ text: part, match: terms.includes(part.toLowerCase()) }));
  }

  function resultClass(position: number) {
    return ["rounded-field block px-3 py-2.5", position === active ? "bg-base-200" : "hover:bg-base-200"];
  }

  function onkeydown(event: KeyboardEvent) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      active = Math.min(active + 1, results.length - 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      active = Math.max(active - 1, 0);
    } else if (event.key === "Enter" && results[active]) {
      event.preventDefault();
      document.getElementById(`search-result-${active}`)?.click();
    }
  }

  function onWindowKeydown(event: KeyboardEvent) {
    const target = event.target as HTMLElement;
    const typing = target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName);
    if ((event.key === "k" && (event.metaKey || event.ctrlKey)) || (event.key === "/" && !typing)) {
      event.preventDefault();
      searchDialog.open = true;
    }
  }
</script>

{#snippet resultContent(result: Result)}
  <span class="flex items-baseline gap-2">
    <span class="badge badge-ghost badge-sm shrink-0">{result.kind}</span>
    <span class="truncate text-sm font-semibold">{result.section || result.title}</span>
  </span>
  {#if result.section && result.section !== result.title}
    <span class="text-base-content/70 mt-0.5 block text-xs">{result.title}</span>
  {/if}
  <span class="text-base-content/80 mt-1 line-clamp-2 block text-sm">
    {#each parts(snippet(result.text)) as part, i (i)}
      {#if part.match}<mark class="bg-primary/20 text-base-content rounded-sm">{part.text}</mark>{:else}{part.text}{/if}
    {/each}
  </span>
{/snippet}

<svelte:window onkeydown={onWindowKeydown} />

<dialog
  bind:this={dialog}
  class="bg-base-100 text-base-content rounded-box border-base-300 m-auto mt-[10vh] w-[min(42rem,calc(100vw-2rem))] border p-0 shadow-lg backdrop:bg-black/40"
  aria-label="Search the docs"
  onclose={() => (searchDialog.open = false)}
  onclick={(event) => {
    if (event.target === dialog) searchDialog.open = false;
  }}
>
  <div class="border-base-300 flex items-center gap-3 border-b px-4">
    <SearchIcon class="text-base-content/60 size-5 shrink-0" aria-hidden="true" />
    <input
      bind:this={input}
      bind:value={query}
      {onkeydown}
      type="text"
      class="h-14 w-full bg-transparent text-base outline-none"
      placeholder="Search the docs, examples and API"
      aria-label="Search"
      role="combobox"
      aria-expanded={results.length > 0}
      aria-controls="search-results"
      aria-activedescendant={results.length > 0 ? `search-result-${active}` : undefined}
      autocomplete="off"
      spellcheck="false"
    />
    <button type="button" class="btn btn-square btn-ghost btn-sm" aria-label="Close search" onclick={() => (searchDialog.open = false)}>
      <X class="size-4" aria-hidden="true" />
    </button>
  </div>

  <div class="max-h-[60vh] overflow-y-auto p-2">
    {#if failed}
      <p class="text-error p-4 text-sm">We couldn't load the search. Check your connection and try again.</p>
    {:else if !index}
      <p class="text-base-content/70 p-4 text-sm">Loading the search…</p>
    {:else if query.trim() === ""}
      <p class="text-base-content/70 p-4 text-sm">Type to search guides, example apps and modules.</p>
    {:else if results.length === 0}
      <p class="text-base-content/70 p-4 text-sm">Nothing matches “{query.trim()}”. Try another word.</p>
    {:else}
      <ul id="search-results" role="listbox" aria-label="Results">
        {#each results as result, position (result.id)}
          <li role="option" aria-selected={position === active}>
            {#if result.kind === "API"}
              <a
                id="search-result-{position}"
                href={result.url}
                rel="external"
                class={resultClass(position)}
                onmouseenter={() => (active = position)}
                onclick={() => (searchDialog.open = false)}
              >
                {@render resultContent(result)}
              </a>
            {:else}
              <a
                id="search-result-{position}"
                href={resolve(result.url as PathnameWithSearchOrHash)}
                class={resultClass(position)}
                onmouseenter={() => (active = position)}
                onclick={() => (searchDialog.open = false)}
              >
                {@render resultContent(result)}
              </a>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</dialog>
