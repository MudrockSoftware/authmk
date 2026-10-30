<script lang="ts">
  import { goto } from "$app/navigation";
  import Ban from "@lucide/svelte/icons/ban";
  import LogIn from "@lucide/svelte/icons/log-in";
  import LogOut from "@lucide/svelte/icons/log-out";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Undo2 from "@lucide/svelte/icons/undo-2";
  import Confirm from "#lib/components/Confirm.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import { api, type UserDetail } from "#lib/api.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  // What an admin does to a whole account: sign out, impersonate, ban, delete.
  let { detail, outcome }: { detail: UserDetail; outcome: Outcome } = $props();

  const can = $derived(session.me!.can);
  const user = $derived(detail.user);
  const self = $derived(user.id === session.me!.user.id);

  const durations = [
    { label: "Until unbanned", seconds: 0 },
    { label: "1 hour", seconds: 3600 },
    { label: "1 day", seconds: 86_400 },
    { label: "7 days", seconds: 604_800 },
    { label: "30 days", seconds: 2_592_000 }
  ];

  let ban = $state({ reason: "", seconds: 0 });
  let banDialog = $state<FormDialog>();
  let confirmRevokeAll = $state<Confirm>();
  let confirmImpersonate = $state<Confirm>();
  let confirmDelete = $state<Confirm>();

  function openBan() {
    ban = { reason: "", seconds: 0 };
    banDialog?.open();
  }

  async function banUser() {
    await api.ban(user.id, ban.reason.trim(), ban.seconds || null);
    await outcome.done("User banned.");
  }

  async function revokeAll() {
    await api.userAction(user.id, "revoke-sessions");
    await outcome.done("Signed out everywhere.");
  }

  // The session cookies are set: the app opens as the user.
  async function impersonate() {
    await api.userAction(user.id, "impersonate");
    window.location.assign("/");
  }

  async function remove() {
    await api.userAction(user.id, "delete");
    await goto("#/users");
  }
</script>

<div class="flex flex-wrap gap-2">
  {#if can.revoke_sessions && detail.sessions.length > 0}
    <button class="btn btn-sm" onclick={() => confirmRevokeAll?.open()}><LogOut class="size-4" /> Sign out everywhere</button>
  {/if}
  {#if can.impersonate && !self}
    <button class="btn btn-sm" onclick={() => confirmImpersonate?.open()}><LogIn class="size-4" /> Impersonate</button>
  {/if}
  {#if can.ban && user.banned !== null && !self}
    {#if user.banned}
      <button class="btn btn-sm" onclick={() => outcome.attempt(() => api.userAction(user.id, "unban"), "User unbanned.")}><Undo2 class="size-4" /> Unban</button>
    {:else}
      <button class="btn btn-sm btn-error btn-soft" onclick={openBan}><Ban class="size-4" /> Ban</button>
    {/if}
  {/if}
  {#if can.delete_users && !self}
    <button class="btn btn-sm btn-error btn-soft" onclick={() => confirmDelete?.open()}><Trash2 class="size-4" /> Delete</button>
  {/if}
</div>

<FormDialog bind:this={banDialog} title="Ban this user?" submitLabel="Ban user" danger run={banUser}>
  <p class="text-base-content/80 text-sm">They're signed out everywhere and can't sign in until the ban ends.</p>
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">Reason (optional)</span>
    <input class="input w-full" bind:value={ban.reason} placeholder="Spam" maxlength="200" />
    <span class="label whitespace-normal">They may see it when they try to sign in.</span>
  </label>
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">How long</span>
    <select class="select w-full" bind:value={ban.seconds}>
      {#each durations as duration (duration.seconds)}<option value={duration.seconds}>{duration.label}</option>{/each}
    </select>
  </label>
</FormDialog>

<Confirm
  bind:this={confirmRevokeAll}
  title="Sign this user out everywhere?"
  message="Every session ends. They can sign in again."
  confirmLabel="Sign out everywhere"
  run={revokeAll}
/>
<Confirm
  bind:this={confirmImpersonate}
  title="Impersonate this user?"
  message="You're signed in to the app as them, and see what they see, until you stop impersonating or the session ends. It's recorded in the audit log."
  confirmLabel="Impersonate"
  run={impersonate}
/>
<Confirm
  bind:this={confirmDelete}
  title="Delete this user?"
  message="Their account, sessions and sign-in methods are deleted. This can't be undone."
  confirmLabel="Delete user"
  danger
  run={remove}
/>
