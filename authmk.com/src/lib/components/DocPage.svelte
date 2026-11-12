<!-- A page of the docs: its HTML from the repository's Markdown, a table of
     contents, and links to the pages before and after it. -->
<script lang="ts">
  import type { Path } from "$app/types";
  import { resolve } from "$app/paths";
  import ArrowLeft from "@lucide/svelte/icons/arrow-left";
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Pencil from "@lucide/svelte/icons/pencil";
  import { page } from "$app/state";
  import { mudrockOrganization, site } from "#lib/site.ts";
  import Seo from "./Seo.svelte";
  import StructuredData from "./StructuredData.svelte";

  type PageLink = { title: string; path: Path } | null;
  type Props = {
    doc: {
      title: string;
      html: string;
      headings: { depth: number; id: string; text: string }[];
      source: string;
      previous: PageLink;
      next: PageLink;
    };
  };

  let { doc }: Props = $props();

  // Code blocks have a "Copy" button (see markdown.ts); one listener serves them all.
  async function copyCode(event: MouseEvent) {
    const button = (event.target as HTMLElement).closest<HTMLButtonElement>("[data-copy-code]");
    const code = button?.parentElement?.querySelector("pre")?.textContent;
    if (!button || code == null) return;
    try {
      await navigator.clipboard.writeText(code);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Couldn't copy";
    }
    setTimeout(() => (button.textContent = "Copy"), 2000);
  }
</script>

<Seo title={doc.title} />
<StructuredData
  data={{
    "@graph": [
      {
        "@type": "TechArticle",
        headline: doc.title,
        url: new URL(page.url.pathname, site.url).href,
        inLanguage: "en-GB",
        about: { "@id": `${site.url}/#software` },
        author: { "@id": mudrockOrganization["@id"] },
        publisher: mudrockOrganization,
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: [
          { "@type": "ListItem", position: 1, name: "Docs", item: `${site.url}/docs` },
          { "@type": "ListItem", position: 2, name: doc.title, item: new URL(page.url.pathname, site.url).href },
        ],
      },
    ],
  }}
/>

<div class="xl:grid xl:grid-cols-[minmax(0,1fr)_16rem] xl:gap-12">
  <article class="mx-auto w-full max-w-[64rem] min-w-0 py-10">
    <h1 class="text-4xl font-bold tracking-tight">{doc.title}</h1>
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <div class="docs-prose prose xl:prose-lg mt-8 max-w-none" onclick={copyCode}>
      <!-- eslint-disable-next-line svelte/no-at-html-tags -- authmk's own Markdown, rendered at build time (markdown.ts). -->
      {@html doc.html}
    </div>

    <div class="border-base-300 mt-12 border-t pt-6">
      <a href={doc.source} rel="external" class="link link-hover text-base-content/70 inline-flex items-center gap-2 text-sm">
        <Pencil class="size-4" aria-hidden="true" />
        Edit this page on GitHub
      </a>
      <nav aria-label="Previous and next pages" class="mt-6 grid gap-4 sm:grid-cols-2">
        {#if doc.previous}
          <a href={resolve(doc.previous.path)} class="border-base-300 hover:border-primary/50 rounded-box border p-4 transition-colors">
            <span class="text-base-content/70 flex items-center gap-1 text-xs"><ArrowLeft class="size-3.5" aria-hidden="true" /> Previous</span>
            <span class="mt-1 block font-medium">{doc.previous.title}</span>
          </a>
        {:else}
          <span></span>
        {/if}
        {#if doc.next}
          <a href={resolve(doc.next.path)} class="border-base-300 hover:border-primary/50 rounded-box border p-4 text-end transition-colors">
            <span class="text-base-content/70 flex items-center justify-end gap-1 text-xs">Next <ArrowRight class="size-3.5" aria-hidden="true" /></span>
            <span class="mt-1 block font-medium">{doc.next.title}</span>
          </a>
        {/if}
      </nav>
    </div>
  </article>

  {#if doc.headings.length > 1}
    <aside class="hidden xl:block">
      <nav aria-label="On this page" class="sticky top-16 max-h-[calc(100vh-4rem)] overflow-y-auto py-10">
        <h2 class="text-base-content/60 text-xs font-semibold">On this page</h2>
        <ul class="mt-3 space-y-2 text-sm">
          {#each doc.headings as heading (heading.id)}
            <li class={heading.depth === 3 ? "ps-3" : ""}>
              <a href="#{heading.id}" class="text-base-content/70 hover:text-base-content transition-colors">{heading.text}</a>
            </li>
          {/each}
        </ul>
      </nav>
    </aside>
  {/if}
</div>
