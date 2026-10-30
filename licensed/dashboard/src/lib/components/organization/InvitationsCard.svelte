<script lang="ts">
  import Send from "@lucide/svelte/icons/send";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import RoleSelect from "#lib/components/organization/RoleSelect.svelte";
  import { api, type Invitation, type OrganizationDetail } from "#lib/api.ts";
  import { formatDate, humanise } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  let { detail, outcome, editable }: { detail: OrganizationDetail; outcome: Outcome; editable: boolean } = $props();

  const id = $derived(detail.organization.id);
  const teams = $derived(session.me!.features.teams ? detail.teams : []);
  const teamName = (teamId: string | null) => detail.teams.find((team) => team.id === teamId)?.name;
  const defaultRole = $derived(detail.roles.find((role) => role.name === "member")?.name ?? detail.roles[0]?.name ?? "");

  let draft = $state({ email: "", role: "", team_id: "" });
  let inviteDialog = $state<FormDialog>();
  let canceling = $state<Invitation | null>(null);
  let confirmCancel = $state<Confirm>();

  function openInvite() {
    draft = { email: "", role: defaultRole, team_id: "" };
    inviteDialog?.open();
  }

  async function invite() {
    await api.invite(id, { email: draft.email.trim(), role: draft.role, team_id: draft.team_id || undefined });
    await outcome.done("Invitation sent.");
  }

  async function cancel() {
    await api.cancelInvitation(id, canceling!.id);
    await outcome.done("Invitation cancelled.");
  }

  const style = (status: string) =>
    ({ pending: "badge-info", accepted: "badge-success", rejected: "badge-warning" })[status] ?? "badge-ghost";
</script>

<Card title="Invitations" count={detail.invitations.length}>
  {#snippet actions()}
    {#if editable}<button class="btn btn-sm" onclick={openInvite}><Send class="size-4" /> Invite</button>{/if}
  {/snippet}
  {#if detail.invitations.length === 0}
    <Empty message="No invitations." />
  {:else}
    <ul class="divide-base-300 divide-y text-sm">
      {#each detail.invitations as invitation (invitation.id)}
        <li class="flex items-center gap-2 py-2">
          <div class="min-w-0 flex-1">
            <div class="truncate">{invitation.email}</div>
            <div class="text-base-content/70 text-xs">
              {invitation.role}{teamName(invitation.team_id) ? ` · ${teamName(invitation.team_id)}` : ""} · expires {formatDate(invitation.expires_at)}
            </div>
          </div>
          <span class="badge {style(invitation.status)} badge-soft badge-sm">{humanise(invitation.status)}</span>
          {#if editable && invitation.status === "pending"}
            <button class="btn btn-ghost btn-xs" onclick={() => { canceling = invitation; confirmCancel?.open(); }}>Cancel</button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>

<FormDialog bind:this={inviteDialog} title="Invite someone" submitLabel="Send invitation" run={invite}>
  <TextField label="Email" type="email" required autocomplete="off" hint="They get an email with a link to join." bind:value={draft.email} />
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">Role</span>
    <RoleSelect roles={detail.roles} bind:value={draft.role} required />
  </label>
  {#if teams.length > 0}
    <label class="fieldset py-0">
      <span class="fieldset-legend pb-1">Team (optional)</span>
      <select class="select w-full" bind:value={draft.team_id}>
        <option value="">No team</option>
        {#each teams as team (team.id)}<option value={team.id}>{team.name}</option>{/each}
      </select>
    </label>
  {/if}
</FormDialog>

<Confirm
  bind:this={confirmCancel}
  title="Cancel the invitation to {canceling?.email ?? 'them'}?"
  message="Its link stops working. You can invite them again."
  confirmLabel="Cancel invitation"
  danger
  run={cancel}
/>
