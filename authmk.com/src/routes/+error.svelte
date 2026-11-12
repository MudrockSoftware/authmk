<script lang="ts">
  import { resolve } from "$app/paths";
  import { page } from "$app/state";
  import Seo from "#lib/components/Seo.svelte";

  const notFound = $derived(page.status === 404);
</script>

<Seo title={notFound ? "Page not found" : "Something went wrong"} noindex />

<section class="site-container py-24 text-center">
  <p class="text-primary text-sm font-semibold">{page.status}</p>
  <h1 class="mt-2 text-4xl font-bold tracking-tight">{notFound ? "Page not found" : "Something went wrong"}</h1>
  <p class="text-base-content/80 mx-auto mt-4 max-w-md">
    {notFound ? "This page doesn't exist. Search the docs, or start from the overview." : "Reload the page to try again."}
  </p>
  <a href={resolve("/docs")} class="btn btn-primary mt-8">Go to the docs</a>
</section>
