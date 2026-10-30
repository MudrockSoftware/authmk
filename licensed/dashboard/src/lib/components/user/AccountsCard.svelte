<script lang="ts">
  import Unlink from "@lucide/svelte/icons/unlink";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import { api, type LinkedAccount } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  // How they sign in: a password ("credential") and linked providers. Their
  // only way to sign in can't be unlinked.
  let { userId, accounts, outcome }: { userId: string; accounts: LinkedAccount[]; outcome: Outcome } = $props();

  const canUnlink = $derived(session.me!.can.update_users && accounts.length > 1);

  let unlinking = $state<LinkedAccount | null>(null);
  let confirmUnlink = $state<Confirm>();

  async function unlink() {
    await api.unlinkAccount(userId, unlinking!.id);
    await outcome.done("Account unlinked.");
  }
</script>

<Card title="Sign-in methods" count={accounts.length}>
  {#if accounts.length === 0}
    <Empty message="No sign-in methods." />
  {:else}
    <ul class="divide-base-300 divide-y text-sm">
      {#each accounts as account (account.id)}
        <li class="flex items-center gap-2 py-2">
          <div class="min-w-0 flex-1">
            <span class="badge badge-outline">{account.provider}</span>
            <div class="text-base-content/70 mt-1 truncate text-xs">Linked {formatDate(account.created_at)}</div>
          </div>
          {#if canUnlink}
            <button class="btn btn-ghost btn-xs" onclick={() => { unlinking = account; confirmUnlink?.open(); }}><Unlink class="size-3.5" /> Unlink</button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>

<Confirm
  bind:this={confirmUnlink}
  title="Unlink {unlinking?.provider ?? 'this account'}?"
  message="They can't sign in with it any more, unless they link it again."
  confirmLabel="Unlink"
  danger
  run={unlink}
/>
