<script lang="ts">
  import "./layout.css";
  import favicon from "#lib/assets/favicon.svg";
  import Search from "#lib/components/Search.svelte";
  import SiteFooter from "#lib/components/SiteFooter.svelte";
  import SiteHeader from "#lib/components/SiteHeader.svelte";
  import type { LayoutProps } from "./$types";

  let { children }: LayoutProps = $props();
</script>

<svelte:head>
  <link rel="icon" href={favicon} />
</svelte:head>

<a href="#main" class="btn btn-primary btn-sm fixed start-4 top-2 z-50 -translate-y-20 focus:translate-y-0">
  Skip to content
</a>

<div class="flex min-h-screen flex-col">
  <SiteHeader />
  <main id="main" class="flex-1">
    {@render children()}
  </main>
  <SiteFooter />
</div>

<Search />
