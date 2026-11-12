<script lang="ts">
  import { resolve } from "$app/paths";
  import { page } from "$app/state";
  import ChevronDown from "@lucide/svelte/icons/chevron-down";
  import type { LayoutProps } from "./$types";

  let { data, children }: LayoutProps = $props();

  let menu = $state<HTMLDetailsElement>();

  // On small screens the sidebar folds away; close it after following a link.
  $effect(() => {
    void page.url.pathname;
    if (menu) menu.open = false;
  });
</script>

{#snippet sidebar()}
  <nav aria-label="Docs">
    {#each data.navigation as group (group.title)}
      <h2 class="text-base-content/60 mt-6 mb-2 px-3 text-xs font-semibold first:mt-0">{group.title}</h2>
      <ul class="space-y-0.5">
        {#each group.pages as link (link.path)}
          {@const href = resolve(link.path)}
          {@const current = page.url.pathname === href}
          <li>
            <a
              {href}
              class={[
                "rounded-field block px-3 py-1.5 text-sm transition-colors",
                current
                  ? "bg-primary text-primary-content font-medium"
                  : "text-base-content/80 hover:bg-base-200 hover:text-base-content",
              ]}
              aria-current={current ? "page" : undefined}
            >
              {link.title}
            </a>
          </li>
        {/each}
      </ul>
    {/each}
  </nav>
{/snippet}

<div class="site-container lg:grid lg:grid-cols-[17rem_minmax(0,1fr)] lg:gap-12">
  <details bind:this={menu} class="border-base-300 group border-b py-3 lg:hidden">
    <summary class="flex cursor-pointer list-none items-center justify-between text-sm font-medium">
      Docs menu
      <ChevronDown class="size-4 transition-transform group-open:rotate-180" aria-hidden="true" />
    </summary>
    <div class="pt-4 pb-2">{@render sidebar()}</div>
  </details>

  <aside class="hidden lg:block">
    <div class="sticky top-16 max-h-[calc(100vh-4rem)] overflow-y-auto py-10 pe-2">
      {@render sidebar()}
    </div>
  </aside>

  <div class="min-w-0">
    {@render children()}
  </div>
</div>
