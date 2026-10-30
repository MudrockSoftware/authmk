<script lang="ts">
  import type { Component } from "svelte";

  let { title, value, detail, icon: Icon }: { title: string; value: string; detail?: string; icon: Component } = $props();
</script>

<div class="card border-base-300 bg-base-100 border">
  <div class="card-body gap-1 p-5">
    <div class="text-base-content/70 flex items-center justify-between text-sm font-medium">
      {title}
      <span class="bg-primary/10 text-primary rounded-field p-1.5"><Icon class="size-4" aria-hidden="true" /></span>
    </div>
    <div class="text-3xl font-semibold tabular-nums">{value}</div>
    {#if detail}<div class="text-base-content/70 text-xs">{detail}</div>{/if}
  </div>
</div>
