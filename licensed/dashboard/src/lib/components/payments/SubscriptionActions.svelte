<script lang="ts">
  import FormDialog from "#lib/components/FormDialog.svelte";
  import { api, type ListedSubscription, type Payments } from "#lib/api.ts";
  import { formatDate, money } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  // Changing a subscription's plan, cancelling and resuming it, through the
  // provider: only what it supports.
  let { subscription, setup, outcome }: { subscription: ListedSubscription; setup: Payments; outcome: Outcome } = $props();

  const live = $derived(subscription.status === "active" || subscription.status === "trialing");
  const canChange = $derived(setup.supports.change_plan && live);
  const canCancel = $derived(setup.supports.cancel && live && !subscription.cancel_at_period_end);
  const canResume = $derived(setup.supports.resume && live && subscription.cancel_at_period_end === true);

  let plan = $state("");
  let annual = $state(false);
  let immediately = $state(false);
  let changeDialog = $state<FormDialog>();
  let cancelDialog = $state<FormDialog>();

  const chosen = $derived(setup.plans.find((p) => p.name === plan));

  function openChange() {
    plan = subscription.plan ?? setup.plans[0]?.name ?? "";
    annual = false;
    changeDialog?.open();
  }

  function openCancel() {
    immediately = false;
    cancelDialog?.open();
  }

  async function change() {
    await api.changePlan(subscription.id, plan, annual && !!chosen?.annual);
    await outcome.done("Plan changed.");
  }

  async function cancel() {
    await api.cancelSubscription(subscription.id, immediately);
    await outcome.done(immediately ? "Subscription cancelled." : "Subscription set to end with its period.");
  }

  const price = (amount: number | null, currency: string | null, per: string) => (amount !== null && currency ? `${money(amount, currency)} ${per}` : null);
</script>

<div class="flex justify-end gap-1 whitespace-nowrap">
  {#if canChange}<button class="btn btn-ghost btn-xs" onclick={openChange}>Change plan</button>{/if}
  {#if canResume}<button class="btn btn-ghost btn-xs" onclick={() => outcome.attempt(() => api.resumeSubscription(subscription.id), "Subscription resumed.")}>Resume</button>{/if}
  {#if canCancel}<button class="btn btn-ghost btn-xs text-error" onclick={openCancel}>Cancel</button>{/if}
</div>

<FormDialog bind:this={changeDialog} title="Change the plan" submitLabel="Change plan" run={change}>
  <p class="text-base-content/80 text-sm">For {subscription.reference_name ?? "this customer"}. The provider prorates the change as it's set up to.</p>
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">Plan</span>
    <select class="select w-full" bind:value={plan} required>
      {#each setup.plans as option (option.name)}
        <option value={option.name}>
          {option.name}{option.name === subscription.plan ? " (current)" : ""}{price(option.amount, option.currency, "a month") ? ` · ${price(option.amount, option.currency, "a month")}` : ""}
        </option>
      {/each}
    </select>
  </label>
  {#if chosen?.annual}
    <label class="label text-base-content gap-2 text-sm">
      <input type="checkbox" class="toggle toggle-sm toggle-primary" bind:checked={annual} />
      Bill yearly{price(chosen.annual_amount, chosen.currency, "a year") ? ` (${price(chosen.annual_amount, chosen.currency, "a year")})` : ""}
    </label>
  {/if}
</FormDialog>

<FormDialog bind:this={cancelDialog} title="Cancel this subscription?" submitLabel="Cancel subscription" danger run={cancel}>
  <p class="text-base-content/80 text-sm">For {subscription.reference_name ?? "this customer"}, on {subscription.plan ?? "their plan"}.</p>
  <label class="label text-base-content gap-2 text-sm">
    <input type="radio" class="radio radio-sm" name="when-{subscription.id}" value={false} bind:group={immediately} />
    At the end of the period{subscription.period_end ? ` (${formatDate(subscription.period_end)})` : ""}: they keep it until then, and can resume
  </label>
  <label class="label text-base-content gap-2 text-sm">
    <input type="radio" class="radio radio-sm" name="when-{subscription.id}" value={true} bind:group={immediately} />
    Now: it ends at once
  </label>
</FormDialog>
