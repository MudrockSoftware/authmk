<script lang="ts">
  import { resolve } from "$app/paths";
  import { page } from "$app/state";
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import SearchIcon from "@lucide/svelte/icons/search";
  import { searchDialog } from "#lib/search-dialog.svelte.ts";
  import { site } from "#lib/site.ts";
  import GithubIcon from "./GithubIcon.svelte";
  import Logo from "./Logo.svelte";
  import ThemeToggle from "./ThemeToggle.svelte";

  const links = [
    { href: resolve("/docs"), label: "Docs" },
    { href: resolve("/examples"), label: "Examples" },
  ];

  // "page" on the link's own page; "true" on the pages under it.
  function ariaCurrent(href: string): "page" | "true" | undefined {
    if (page.url.pathname === href) return "page";
    return current(href) ? "true" : undefined;
  }

  function current(href: string): boolean {
    return page.url.pathname === href || page.url.pathname.startsWith(`${href}/`);
  }
</script>

<header class="border-base-300 bg-base-100/90 sticky top-0 z-40 border-b backdrop-blur-sm">
  <div class="site-container flex h-16 items-center gap-4">
    <a href={resolve("/")} class="shrink-0" aria-label="authmk home"><Logo /></a>

    <nav aria-label="Main" class="ms-2 hidden sm:block">
      <ul class="flex items-center gap-1">
        {#each links as link (link.href)}
          <li>
            <a
              href={link.href}
              class={["btn btn-ghost btn-sm font-medium", current(link.href) && "text-primary"]}
              aria-current={ariaCurrent(link.href)}
            >
              {link.label}
            </a>
          </li>
        {/each}
        <li>
          <a href={site.hexdocs} rel="external" class="btn btn-ghost btn-sm font-medium">
            API reference
            <ExternalLink class="size-3.5" aria-hidden="true" />
          </a>
        </li>
      </ul>
    </nav>

    <div class="ms-auto flex items-center gap-1">
      <button
        type="button"
        class="btn btn-sm border-base-300 bg-base-200 text-base-content/70 hover:text-base-content hidden w-56 justify-start gap-2 font-normal md:inline-flex"
        onclick={() => (searchDialog.open = true)}
      >
        <SearchIcon class="size-4" aria-hidden="true" />
        Search
        <kbd class="kbd kbd-sm ms-auto">/</kbd>
      </button>
      <button
        type="button"
        class="btn btn-square btn-ghost btn-sm md:hidden"
        aria-label="Search"
        onclick={() => (searchDialog.open = true)}
      >
        <SearchIcon class="size-4" aria-hidden="true" />
      </button>
      <ThemeToggle />
      <a href={site.github} rel="external" class="btn btn-square btn-ghost btn-sm" aria-label="authmk on GitHub">
        <GithubIcon />
      </a>
    </div>
  </div>

  <!-- On small screens the links sit in a row under the logo. -->
  <nav aria-label="Main" class="border-base-300 border-t sm:hidden">
    <ul class="site-container flex h-11 items-center gap-1">
      {#each links as link (link.href)}
        <li>
          <a
            href={link.href}
            class={["btn btn-ghost btn-sm font-medium", current(link.href) && "text-primary"]}
            aria-current={ariaCurrent(link.href)}
          >
            {link.label}
          </a>
        </li>
      {/each}
      <li>
        <a href={site.hexdocs} rel="external" class="btn btn-ghost btn-sm font-medium">API reference</a>
      </li>
    </ul>
  </nav>
</header>
