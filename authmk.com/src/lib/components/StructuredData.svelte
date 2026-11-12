<!-- schema.org data for search engines, as JSON-LD in <head>. -->
<script lang="ts">
  type Props = { data: Record<string, unknown> };

  let { data }: Props = $props();

  // "<" is escaped so the JSON can't close the <script> early; the closing tag
  // is split for the same reason.
  const tag = $derived(
    `<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", ...data }).replaceAll("<", "\\u003c")}<${"/"}script>`
  );
</script>

<svelte:head>
  <!-- eslint-disable-next-line svelte/no-at-html-tags -- our own JSON, with "<" escaped. -->
  {@html tag}
</svelte:head>
