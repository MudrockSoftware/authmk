<script lang="ts">
  import type { Subscription } from "#lib/api.ts";
  import { formatDate, humanise } from "#lib/format.ts";

  let { subscription }: { subscription: Subscription } = $props();

  const style = $derived(
    ({ active: "badge-success", trialing: "badge-info", past_due: "badge-warning", unpaid: "badge-error" } as Record<string, string>)[subscription.status] ??
      "badge-ghost"
  );
</script>

<span class="inline-flex flex-wrap items-center gap-1">
  <span class="badge {style} badge-soft badge-sm">{humanise(subscription.status)}</span>
  {#if subscription.cancel_at_period_end}
    <span class="badge badge-warning badge-soft badge-sm">Ends {formatDate(subscription.period_end)}</span>
  {/if}
</span>
