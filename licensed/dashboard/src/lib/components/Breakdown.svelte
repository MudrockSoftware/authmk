<script lang="ts">
  import { humanise } from "#lib/format.ts";

  // Counts by name, most first, each with its share of the total.
  let { rows, label }: { rows: { name: string; count: number }[]; label: string } = $props();

  const total = $derived(rows.reduce((sum, row) => sum + row.count, 0));
</script>

<ul class="flex flex-col gap-3" aria-label={label}>
  {#each rows as row (row.name)}
    <li class="text-sm">
      <div class="flex justify-between gap-2">
        <span>{humanise(row.name)}</span>
        <span class="text-base-content/70 tabular-nums">{row.count.toLocaleString("en-GB")} · {Math.round((row.count / total) * 100)}%</span>
      </div>
      <progress class="progress progress-primary h-1.5" value={row.count} max={total}></progress>
    </li>
  {/each}
</ul>
