<script lang="ts">
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import OutcomeAlert from "#lib/components/OutcomeAlert.svelte";
  import SubscriptionStatus from "#lib/components/SubscriptionStatus.svelte";
  import SubscriptionActions from "#lib/components/payments/SubscriptionActions.svelte";
  import { api, type ListedSubscription, type Payments } from "#lib/api.ts";
  import { formatDate, humanise, money } from "#lib/format.ts";
  import { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  // Every subscription, newest first, with filters; changes reload the page's earnings too.
  let { setup, onchange }: { setup: Payments; onchange: () => Promise<void> } = $props();

  const me = $derived(session.me!);
  const canManage = $derived(me.can.manage_subscriptions && (setup.supports.cancel || setup.supports.change_plan || setup.supports.resume));

  let status = $state("");
  let plan = $state("");
  let referenceType = $state("");
  let subscriptions = $state<ListedSubscription[]>([]);
  let hasMore = $state(false);
  let loading = $state(true);
  let failure = $state<unknown>(null);
  const outcome = new Outcome(async () => {
    await Promise.all([load(), onchange()]);
  });

  const filters = $derived({ status, plan, reference_type: referenceType });

  async function load(more = false) {
    loading = true;
    failure = null;
    try {
      const page = await api.subscriptions(filters, more ? subscriptions.length : 0);
      subscriptions = more ? [...subscriptions, ...page.subscriptions] : page.subscriptions;
      hasMore = page.has_more;
    } catch (error) {
      failure = error;
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    void filters;
    load();
  });

  const statuses = $derived(Object.keys(setup.earnings.by_status).sort());
  const link = (s: ListedSubscription) => (s.reference_type === "user" ? `#/users/${s.reference_id}` : `#/organizations/${s.reference_id}`);
</script>

<Card title="Subscriptions">
  {#snippet actions()}
    <select class="select select-sm w-auto" bind:value={status} aria-label="Status">
      <option value="">Any status</option>
      {#each statuses as s (s)}<option value={s}>{humanise(s)}</option>{/each}
    </select>
    <select class="select select-sm w-auto" bind:value={plan} aria-label="Plan">
      <option value="">Any plan</option>
      {#each setup.plans as p (p.name)}<option value={p.name}>{p.name}</option>{/each}
    </select>
    {#if me.features.organizations}
      <select class="select select-sm w-auto" bind:value={referenceType} aria-label="Customer">
        <option value="">Users and organizations</option>
        <option value="user">Users</option>
        <option value="organization">Organizations</option>
      </select>
    {/if}
  {/snippet}

  <OutcomeAlert {outcome} />
  {#if failure}<Failure error={failure} />{/if}

  <div class="overflow-x-auto">
    <table class="table">
      <thead>
        <tr>
          <th>Customer</th><th>Plan</th><th>Status</th><th class="text-right">A month</th><th>Period ends</th><th>Started</th>
          {#if canManage}<th><span class="sr-only">Actions</span></th>{/if}
        </tr>
      </thead>
      <tbody>
        {#each subscriptions as subscription (subscription.id)}
          <tr>
            <td>
              <a class="link link-hover font-medium" href={link(subscription)}>{subscription.reference_name ?? subscription.reference_id}</a>
              <div class="text-base-content/70 text-xs">{subscription.reference_type === "user" ? "User" : "Organization"} · {subscription.provider}</div>
            </td>
            <td>
              {subscription.plan ?? subscription.price_id ?? "—"}
              {#if subscription.seats && subscription.seats > 1}<div class="text-base-content/70 text-xs">{subscription.seats} seats</div>{/if}
            </td>
            <td><SubscriptionStatus {subscription} /></td>
            <td class="text-right tabular-nums">{subscription.monthly_amount ? money(subscription.monthly_amount.amount, subscription.monthly_amount.currency) : "—"}</td>
            <td class="text-sm">{formatDate(subscription.period_end)}</td>
            <td class="text-sm">{formatDate(subscription.created_at)}</td>
            {#if canManage}<td><SubscriptionActions {subscription} {setup} {outcome} /></td>{/if}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
  {#if !loading && subscriptions.length === 0}<Empty message={status || plan || referenceType ? "No subscriptions match these filters." : "No subscriptions yet."} />{/if}
  {#if loading}<Loading />{/if}
  {#if hasMore && !loading}<div class="flex justify-center"><button class="btn btn-sm" onclick={() => load(true)}>Load more</button></div>{/if}
</Card>
