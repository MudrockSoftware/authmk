<script lang="ts">
  import CreditCard from "@lucide/svelte/icons/credit-card";
  import Info from "@lucide/svelte/icons/info";
  import Repeat from "@lucide/svelte/icons/repeat";
  import Card from "#lib/components/Card.svelte";
  import Chart from "#lib/components/Chart.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import StatCard from "#lib/components/StatCard.svelte";
  import type { Payments } from "#lib/api.ts";
  import { count, humanise, money, shortDay } from "#lib/format.ts";

  // Recurring revenue from the plans' prices in config, and how
  // subscriptions came and went in the range.
  let { earnings }: { earnings: Payments["earnings"] } = $props();

  const priced = $derived(earnings.recurring_revenue.filter((r) => r.currency !== null));
  const statuses = $derived(Object.entries(earnings.by_status).sort(([, a], [, b]) => b - a));
</script>

<div class="flex flex-col gap-6">
  <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
    <StatCard title="Active subscriptions" value={earnings.active_subscriptions.toLocaleString("en-GB")} detail="Active or trialing, now" icon={CreditCard} />
    {#each priced as revenue (revenue.currency)}
      <StatCard
        title="Monthly recurring revenue ({revenue.currency!.toUpperCase()})"
        value={money(revenue.monthly, revenue.currency!)}
        detail="{money(revenue.yearly, revenue.currency!)} a year · {count(revenue.subscriptions, 'subscription')}"
        icon={Repeat}
      />
    {/each}
  </div>

  <div role="note" class="alert alert-info alert-soft text-sm">
    <Info class="size-5" aria-hidden="true" />
    <span>
      Revenue is what active subscriptions bill a month at the plan prices in your config (annual plans count a twelfth of their price), not money
      received: authmk doesn't see invoices, refunds or discounts.
      {#if earnings.unpriced_subscriptions > 0}
        {count(earnings.unpriced_subscriptions, "active subscription")} {earnings.unpriced_subscriptions === 1 ? "is" : "are"} on a plan with no price,
        and left out.
      {/if}
    </span>
  </div>

  <div class="grid gap-6 xl:grid-cols-3">
    <Card title="New and cancelled subscriptions" class="xl:col-span-2">
      <Chart
        kind="line"
        label="New and cancelled subscriptions per day"
        labels={earnings.new_subscriptions.map((d) => shortDay(d.day))}
        series={[
          { label: "New", data: earnings.new_subscriptions.map((d) => d.count), colour: "primary" },
          { label: "Cancelled", data: earnings.cancellations.map((d) => d.count), colour: "error" }
        ]}
      />
    </Card>
    <Card title="By status">
      {#if statuses.length === 0}
        <Empty message="No subscriptions yet." />
      {:else}
        <ul class="divide-base-300 divide-y text-sm">
          {#each statuses as [status, total] (status)}
            <li class="flex justify-between py-2"><span>{humanise(status)}</span><span class="tabular-nums">{total.toLocaleString("en-GB")}</span></li>
          {/each}
        </ul>
      {/if}
    </Card>
  </div>

  <Card title="By plan">
    {#if earnings.by_plan.length === 0}
      <Empty message="No active subscriptions." />
    {:else}
      <div class="overflow-x-auto">
        <table class="table">
          <thead><tr><th>Plan</th><th>Provider</th><th class="text-right">Subscriptions</th><th class="text-right">A month</th><th class="text-right">A year</th></tr></thead>
          <tbody>
            {#each earnings.by_plan as row (`${row.plan}/${row.provider}/${row.currency}`)}
              <tr>
                <td class="font-medium">{row.plan ?? "No plan"}</td>
                <td>{row.provider}</td>
                <td class="text-right tabular-nums">{row.subscriptions.toLocaleString("en-GB")}</td>
                {#if row.currency}
                  <td class="text-right tabular-nums">{money(row.monthly, row.currency)}</td>
                  <td class="text-right tabular-nums">{money(row.yearly, row.currency)}</td>
                {:else}
                  <td colspan="2" class="text-base-content/70 text-right text-sm">No price in config</td>
                {/if}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </Card>
</div>
