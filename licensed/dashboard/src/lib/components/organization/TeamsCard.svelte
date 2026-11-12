<script lang="ts">
  import Pencil from "@lucide/svelte/icons/pencil";
  import Plus from "@lucide/svelte/icons/plus";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import X from "@lucide/svelte/icons/x";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type OrganizationDetail, type Team } from "#lib/api.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  // Teams within the organization; their members come from its members.
  // With Authmk.Plugins.Gate, teams and their members have roles too.
  let { detail, outcome, editable }: { detail: OrganizationDetail; outcome: Outcome; editable: boolean } = $props();

  const id = $derived(detail.organization.id);
  const teamRoles = $derived(detail.access?.roles.filter((role) => role.level === "team").map((role) => role.role) ?? []);
  const memberRoles = $derived(detail.access?.roles.filter((role) => role.level === "team_member").map((role) => role.role) ?? []);

  function setTeamRole(team: Team, role: string) {
    outcome.attempt(() => api.setTeamRole(id, team.id, role || null), role ? "Team role set." : "Team role removed.");
  }

  function setMemberRole(team: Team, userId: string, role: string) {
    outcome.attempt(() => api.setTeamMemberRole(id, team.id, userId, role || null), role ? "Role in the team set." : "Role in the team removed.");
  }

  let name = $state("");
  let editing = $state<Team | null>(null);
  let nameDialog = $state<FormDialog>();
  let removing = $state<Team | null>(null);
  let confirmRemove = $state<Confirm>();

  function openName(team: Team | null) {
    editing = team;
    name = team?.name ?? "";
    nameDialog?.open();
  }

  async function saveName() {
    if (editing) await api.renameTeam(id, editing.id, name.trim());
    else await api.createTeam(id, name.trim());
    await outcome.done(editing ? "Team renamed." : "Team created.");
  }

  async function remove() {
    await api.removeTeam(id, removing!.id);
    await outcome.done("Team removed.");
  }

  const outside = (team: Team) => detail.members.filter((member) => !team.members.some((m) => m.id === member.user.id));

  function addMember(team: Team, select: HTMLSelectElement) {
    const userId = select.value;
    select.value = "";
    if (userId) outcome.attempt(() => api.addTeamMember(id, team.id, userId), "Added to the team.");
  }
</script>

<Card title="Teams" count={detail.teams.length}>
  {#snippet actions()}
    {#if editable}<button class="btn btn-sm" onclick={() => openName(null)}><Plus class="size-4" /> New team</button>{/if}
  {/snippet}
  {#if detail.teams.length === 0}
    <Empty message="No teams." />
  {:else}
    <ul class="divide-base-300 divide-y">
      {#each detail.teams as team (team.id)}
        <li class="py-3">
          <div class="flex items-center gap-2">
            <span class="flex-1 font-medium">{team.name}</span>
            {#if detail.access}
              {#if editable}
                <select class="select select-xs w-auto" aria-label="Role of {team.name}" value={team.role ?? ""} onchange={(e) => setTeamRole(team, e.currentTarget.value)}>
                  <option value="">No role</option>
                  {#if team.role && !teamRoles.includes(team.role)}<option value={team.role}>{team.role}</option>{/if}
                  {#each teamRoles as role (role)}<option value={role}>{role}</option>{/each}
                </select>
              {:else}
                <span class="badge badge-primary badge-soft badge-sm">{team.role ?? "No role"}</span>
              {/if}
            {/if}
            {#if editable}
              <button class="btn btn-ghost btn-xs btn-square" aria-label="Rename {team.name}" onclick={() => openName(team)}><Pencil class="size-3.5" /></button>
              <button class="btn btn-ghost btn-xs btn-square text-error" aria-label="Remove {team.name}" onclick={() => { removing = team; confirmRemove?.open(); }}><Trash2 class="size-3.5" /></button>
            {/if}
          </div>
          <ul class="mt-2 flex flex-wrap gap-1">
            {#each team.members as member (member.id)}
              <li class="badge badge-outline gap-1">
                <a class="link link-hover" href="#/users/{member.id}">{member.name ?? member.email}</a>
                {#if detail.access}
                  {#if editable}
                    <select
                      class="cursor-pointer bg-transparent text-xs opacity-70"
                      aria-label="Role of {member.email} in {team.name}"
                      value={member.role ?? ""}
                      onchange={(e) => setMemberRole(team, member.id, e.currentTarget.value)}
                    >
                      <option value="">all the team has</option>
                      {#if member.role && !memberRoles.includes(member.role)}<option value={member.role}>{member.role}</option>{/if}
                      {#each memberRoles as role (role)}<option value={role}>{role}</option>{/each}
                    </select>
                  {:else if member.role}
                    <span class="opacity-70">· {member.role}</span>
                  {/if}
                {/if}
                {#if editable}
                  <button
                    class="cursor-pointer opacity-60 hover:opacity-100"
                    aria-label="Remove {member.email} from {team.name}"
                    onclick={() => outcome.attempt(() => api.removeTeamMember(id, team.id, member.id), "Removed from the team.")}
                  >
                    <X class="size-3" />
                  </button>
                {/if}
              </li>
            {:else}
              <li class="text-base-content/70 text-xs">No members.</li>
            {/each}
          </ul>
          {#if editable && outside(team).length > 0}
            <select class="select select-xs mt-2 w-auto" aria-label="Add a member to {team.name}" onchange={(e) => addMember(team, e.currentTarget)}>
              <option value="">Add a member…</option>
              {#each outside(team) as member (member.user.id)}<option value={member.user.id}>{member.user.name ?? member.user.email}</option>{/each}
            </select>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>

<FormDialog bind:this={nameDialog} title={editing ? "Rename the team" : "New team"} submitLabel={editing ? "Save name" : "Create team"} run={saveName}>
  <TextField label="Name" required autocomplete="off" bind:value={name} />
</FormDialog>

<Confirm
  bind:this={confirmRemove}
  title="Remove {removing?.name ?? 'this team'}?"
  message="The team goes. Its members stay in the organization."
  confirmLabel="Remove team"
  danger
  run={remove}
/>
