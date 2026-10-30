<script lang="ts">
  import ArrowLeft from "@lucide/svelte/icons/arrow-left";
  import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import { readPage } from "#lib/page.ts";

  const page = readPage();
  const appName = page?.app_name && page.app_name !== "authmk" ? page.app_name : null;
</script>

<svelte:head>
  <title>{appName ? `Sign-in problem · ${appName}` : "Sign-in problem"}</title>
</svelte:head>

<main class="flex min-h-screen flex-col items-center justify-center p-6">
  <div class="card border-base-300 bg-base-100 w-full max-w-md border">
    <div class="card-body items-center gap-3 text-center">
      <span class="bg-error/10 text-error rounded-full p-3"><TriangleAlert class="size-7" aria-hidden="true" /></span>
      <h1 class="text-2xl font-semibold">We couldn't sign you in</h1>
      <p class="text-base-content/80">{page?.message ?? "Something went wrong while signing you in. Try again."}</p>
      {#if page?.code}
        <p class="text-base-content/70 text-xs">Error code: <code class="bg-base-200 rounded px-1.5 py-0.5 font-mono">{page.code}</code></p>
      {/if}
      <div class="mt-3 flex flex-wrap justify-center gap-2">
        <a class="btn btn-primary" href={page?.home ?? "/"}><ArrowLeft class="size-4" aria-hidden="true" /> Back to {appName ?? "the app"}</a>
        <button class="btn btn-ghost" onclick={() => history.back()}><RotateCcw class="size-4" aria-hidden="true" /> Try again</button>
      </div>
    </div>
  </div>
  <p class="text-base-content/60 mt-6 text-xs">If this keeps happening, contact {appName ?? "the app"}'s support and give them the code above.</p>
</main>
