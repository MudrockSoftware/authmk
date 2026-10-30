<script lang="ts">
  import type { Range } from "#lib/api.ts";
  import { daysAgo, isoDay } from "#lib/format.ts";

  // From and to dates (both included, UTC), with presets.
  let { range = $bindable() }: { range: Range } = $props();

  const presets = [
    { label: "7 days", days: 7 },
    { label: "30 days", days: 30 },
    { label: "90 days", days: 90 },
    { label: "12 months", days: 365 }
  ];

  const today = isoDay(new Date());
  const preset = (days: number) => ({ from: daysAgo(days - 1), to: today });
  const chosen = (days: number) => range.to === today && range.from === daysAgo(days - 1);

  function set(end: "from" | "to", value: string) {
    if (value) range = { ...range, [end]: value };
  }
</script>

<div class="flex flex-wrap items-end gap-2">
  <div class="join" role="group" aria-label="Date range">
    {#each presets as p (p.days)}
      <button type="button" class="btn btn-sm join-item {chosen(p.days) ? 'btn-primary' : ''}" aria-pressed={chosen(p.days)} onclick={() => (range = preset(p.days))}>
        {p.label}
      </button>
    {/each}
  </div>
  <label class="input input-sm w-auto">
    <span class="label">From</span>
    <input type="date" value={range.from} max={range.to} onchange={(e) => set("from", e.currentTarget.value)} />
  </label>
  <label class="input input-sm w-auto">
    <span class="label">To</span>
    <input type="date" value={range.to} min={range.from} max={today} onchange={(e) => set("to", e.currentTarget.value)} />
  </label>
</div>
