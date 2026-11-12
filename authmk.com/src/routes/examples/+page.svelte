<script lang="ts">
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import FileCode from "@lucide/svelte/icons/file-code";
  import Seo from "#lib/components/Seo.svelte";
  import { githubUrl } from "#lib/site.ts";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();
</script>

<Seo
  title="Example apps"
  description="Two working apps that use authmk, a Phoenix app with LiveView and a plain Plug app, file by file."
/>

<section class="border-base-300 bg-base-200 border-b">
  <div class="site-container py-14">
    <h1 class="max-w-3xl text-4xl font-bold tracking-tight">Example apps</h1>
    <p class="text-base-content/80 mt-4 max-w-2xl text-lg">
      Two small apps that use authmk the way your app would: set up with its mix tasks, with every plugin
      wired in and tested. The code below is their real code, from the repository.
    </p>
    <div class="mt-6 flex flex-wrap gap-2">
      {#each data.apps as app (app.id)}
        <a href="#{app.id}" class="btn btn-outline btn-sm">{app.name}</a>
      {/each}
    </div>
  </div>
</section>

{#each data.apps as app (app.id)}
  <section id={app.id} class="site-container border-base-300 border-b py-14 last:border-b-0">
    <div class="flex flex-wrap items-end justify-between gap-4">
      <div>
        <h2 class="text-3xl font-semibold tracking-tight">{app.name}</h2>
        <p class="text-base-content/80 mt-2 max-w-2xl">{app.summary}</p>
      </div>
      <a href={githubUrl(app.path)} rel="external" class="btn btn-ghost btn-sm">
        All files on GitHub
        <ExternalLink class="size-3.5" aria-hidden="true" />
      </a>
    </div>

    <div class="mt-10 space-y-12">
      {#each app.files as file (file.id)}
        <div id={file.id}>
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h3 class="text-xl font-semibold">{file.title}</h3>
            <a href={githubUrl(file.path)} rel="external" class="link link-hover text-base-content/70 inline-flex items-center gap-1.5 font-mono text-xs">
              <FileCode class="size-3.5" aria-hidden="true" />
              {file.path}
            </a>
          </div>
          <p class="text-base-content/80 mt-1 text-sm">{file.description}</p>
          <div class="mt-4 max-h-[36rem] overflow-y-auto rounded-box">
            <!-- eslint-disable-next-line svelte/no-at-html-tags -- the example apps' code, highlighted at build time. -->
            {@html file.html}
          </div>
        </div>
      {/each}
    </div>
  </section>
{/each}

<section class="site-container py-14">
  <div class="border-base-300 rounded-box border p-6">
    <h2 class="text-xl font-semibold">Run them yourself</h2>
    <p class="text-base-content/80 mt-2 text-sm">Clone the repository, then in either app:</p>
    <pre class="bg-base-200 rounded-field mt-4 overflow-x-auto p-4 font-mono text-sm"><code>cd examples/phoenix_app   # or examples/plug_app
mix setup
mix test</code></pre>
  </div>
</section>
