<script lang="ts">
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import SubscriptionStatus from "#lib/components/SubscriptionStatus.svelte";
  import type { Subscription } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  // A user's or organization's subscriptions; they're managed on the Payments page.
  let { subscriptions }: { subscriptions: Subscription[] } = $props();
</script>

<Card title="Subscriptions" count={subscriptions.length}>
  {#snippet actions()}<a href="#/payments" class="link link-primary text-sm">Payments</a>{/snippet}
  {#if subscriptions.length === 0}
    <Empty message="No subscriptions." />
  {:else}
    <div class="overflow-x-auto">
      <table class="table-sm table">
        <thead><tr><th>Plan</th><th>Status</th><th>Seats</th><th>Period ends</th><th>Provider</th><th>Started</th></tr></thead>
        <tbody>
          {#each subscriptions as subscription (subscription.id)}
            <tr>
              <td class="font-medium">{subscription.plan ?? subscription.price_id ?? "—"}</td>
              <td><SubscriptionStatus {subscription} /></td>
              <td class="tabular-nums">{subscription.seats ?? "—"}</td>
              <td>{formatDate(subscription.period_end)}</td>
              <td>{subscription.provider}</td>
              <td>{formatDate(subscription.created_at)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</Card>
