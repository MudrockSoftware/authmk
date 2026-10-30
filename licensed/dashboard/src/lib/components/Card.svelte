<script lang="ts">
  import type { Snippet } from "svelte";

  let {
    title,
    count,
    actions,
    children,
    class: extra = ""
  }: { title: string; count?: number; actions?: Snippet; children: Snippet; class?: string } = $props();
</script>

<section class="card border-base-300 bg-base-100 border {extra}">
  <div class="card-body">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h2 class="card-title text-base">
        {title}
        {#if count !== undefined}<span class="badge badge-ghost">{count}</span>{/if}
      </h2>
      {#if actions}<div class="flex flex-wrap gap-2">{@render actions()}</div>{/if}
    </div>
    {@render children()}
  </div>
</section>
