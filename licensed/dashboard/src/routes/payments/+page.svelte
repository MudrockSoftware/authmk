<script lang="ts">
  import DateRange from "#lib/components/DateRange.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import Earnings from "#lib/components/payments/Earnings.svelte";
  import SubscriptionsTable from "#lib/components/payments/SubscriptionsTable.svelte";
  import { api, type Payments, type Range } from "#lib/api.ts";
  import { daysAgo, humanise, isoDay } from "#lib/format.ts";

  let range = $state<Range>({ from: daysAgo(29), to: isoDay(new Date()) });
  let payments = $state<Payments | null>(null);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  // Only the latest answer counts, if the range changed meanwhile.
  let latest = 0;

  async function load(asked: Range) {
    const mine = ++latest;
    loading = true;
    failure = null;
    try {
      const data = await api.payments(asked);
      if (mine === latest) payments = data;
    } catch (error) {
      if (mine === latest) failure = error;
    } finally {
      if (mine === latest) loading = false;
    }
  }

  $effect(() => {
    load(range);
  });
</script>

<PageHeader
  title="Payments"
  description={payments ? `Subscriptions through ${humanise(payments.provider)}, and what they bring in.` : "Subscriptions, and what they bring in."}
/>

<div class="mb-6"><DateRange bind:range /></div>

{#if failure}<Failure error={failure} />{/if}

{#if payments}
  <div class="flex flex-col gap-6">
    <div class={loading ? "opacity-60" : ""} aria-busy={loading}><Earnings earnings={payments.earnings} /></div>
    <SubscriptionsTable setup={payments} onchange={() => load(range)} />
  </div>
{:else if loading}
  <Loading />
{/if}
