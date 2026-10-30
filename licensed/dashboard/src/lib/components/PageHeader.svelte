<script lang="ts">
  import type { Snippet } from "svelte";

  let { title, description, actions }: { title: string; description?: string; actions?: Snippet } = $props();
</script>

<div class="mb-6 flex flex-wrap items-end justify-between gap-4">
  <div>
    <h1 class="text-2xl font-semibold">{title}</h1>
    {#if description}<p class="text-base-content/70 mt-1 text-sm">{description}</p>{/if}
  </div>
  {#if actions}<div class="flex flex-wrap gap-2">{@render actions()}</div>{/if}
</div>
