<!-- Per-page <head> tags for search engines and link previews. Use once per page. -->
<script lang="ts">
  import { page } from "$app/state";
  import { site } from "#lib/site.ts";

  type Props = {
    /** The page's title; the site's name is added. Omit on the home page. */
    title?: string;
    description?: string;
    noindex?: boolean;
  };

  let { title, description = site.description, noindex = false }: Props = $props();

  const fullTitle = $derived(title ? `${title} · authmk` : "authmk: authentication for Elixir");
  const url = $derived(new URL(page.url.pathname, site.url).href);
  const image = new URL(site.socialImage, site.url).href;
</script>

<svelte:head>
  <title>{fullTitle}</title>
  <meta name="description" content={description} />
  {#if noindex}
    <meta name="robots" content="noindex" />
  {:else}
    <link rel="canonical" href={url} />
  {/if}
  <meta property="og:type" content="website" />
  <meta property="og:site_name" content="authmk" />
  <meta property="og:title" content={fullTitle} />
  <meta property="og:description" content={description} />
  <meta property="og:url" content={url} />
  <meta property="og:locale" content="en_GB" />
  <meta property="og:image" content={image} />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:alt" content="authmk: authentication for Elixir, built from plugins" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:image" content={image} />
  <meta name="author" content={site.mudrockName} />
</svelte:head>
