<script lang="ts">
  import ShieldOff from "@lucide/svelte/icons/shield-off";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import { api, type SecondFactors } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  // Which second factors they've set up; never their secrets.
  let { userId, factors, outcome }: { userId: string; factors: SecondFactors; outcome: Outcome } = $props();

  const me = $derived(session.me!);
  let confirmDisable = $state<Confirm>();

  async function disable() {
    await api.userAction(userId, "disable-two-factor");
    await outcome.done("Two-factor turned off.");
  }
</script>

<Card title="Second factors">
  {#snippet actions()}
    {#if me.can.update_users && factors.enabled}
      <button class="btn btn-sm" onclick={() => confirmDisable?.open()}><ShieldOff class="size-4" /> Turn off two-factor</button>
    {/if}
  {/snippet}
  <dl class="grid grid-cols-[1fr_auto] gap-y-2 text-sm">
    {#if me.features.two_factor}
      <dt>Two-factor</dt>
      <dd><span class="badge {factors.enabled ? 'badge-success' : 'badge-ghost'} badge-soft badge-sm">{factors.enabled ? "On" : "Off"}</span></dd>
      <dt>Authenticator app</dt>
      <dd>{factors.authenticator_app ? "Set up" : "None"}</dd>
    {/if}
    {#if factors.phone_number !== null}
      <dt>Phone number</dt>
      <dd>{factors.phone_number ? "Verified" : "None verified"}</dd>
    {/if}
    {#if me.features.passkeys}
      <dt>Passkeys</dt>
      <dd>{factors.passkeys.length}</dd>
    {/if}
  </dl>
  {#if factors.passkeys.length > 0}
    <ul class="divide-base-300 divide-y text-sm">
      {#each factors.passkeys as passkey (passkey.id)}
        <li class="flex justify-between gap-2 py-2"><span class="truncate">{passkey.name ?? "Unnamed passkey"}</span><span class="text-base-content/70 text-xs">Added {formatDate(passkey.created_at)}</span></li>
      {/each}
    </ul>
  {/if}
</Card>

<Confirm
  bind:this={confirmDisable}
  title="Turn off two-factor?"
  message="Their authenticator app and backup codes stop working. Only do this once you've confirmed who they are."
  confirmLabel="Turn off two-factor"
  danger
  run={disable}
/>
