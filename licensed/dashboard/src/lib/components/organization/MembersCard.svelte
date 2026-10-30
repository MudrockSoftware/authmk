<script lang="ts">
  import UserPlus from "@lucide/svelte/icons/user-plus";
  import UserX from "@lucide/svelte/icons/user-x";
  import Avatar from "#lib/components/Avatar.svelte";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import RoleSelect from "#lib/components/organization/RoleSelect.svelte";
  import { api, type Member, type OrganizationDetail } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  let { detail, outcome, editable }: { detail: OrganizationDetail; outcome: Outcome; editable: boolean } = $props();

  const id = $derived(detail.organization.id);
  const defaultRole = $derived(detail.roles.find((role) => role.name === "member")?.name ?? detail.roles[0]?.name ?? "");

  let adding = $state({ email: "", role: "" });
  let addDialog = $state<FormDialog>();
  let removing = $state<Member | null>(null);
  let confirmRemove = $state<Confirm>();

  function openAdd() {
    adding = { email: "", role: defaultRole };
    addDialog?.open();
  }

  async function add() {
    await api.addMember(id, adding.email.trim(), adding.role);
    await outcome.done("Member added.");
  }

  function setRole(member: Member, role: string) {
    if (role !== member.role) outcome.attempt(() => api.setMemberRole(id, member.user.id, role), "Role changed.");
  }

  async function remove() {
    await api.removeMember(id, removing!.user.id);
    await outcome.done("Member removed.");
  }
</script>

<Card title="Members" count={detail.members.length}>
  {#snippet actions()}
    {#if editable}<button class="btn btn-sm" onclick={openAdd}><UserPlus class="size-4" /> Add member</button>{/if}
  {/snippet}
  {#if detail.members.length === 0}
    <Empty message="No members." />
  {:else}
    <ul class="divide-base-300 divide-y">
      {#each detail.members as member (member.user.id)}
        <li class="flex flex-wrap items-center gap-3 py-2.5">
          <a href="#/users/{member.user.id}" class="hover:bg-base-200 rounded-field flex min-w-0 flex-1 items-center gap-3 px-2 py-1">
            <Avatar name={member.user.name} email={member.user.email} />
            <div class="min-w-0 text-sm">
              <div class="truncate font-medium">{member.user.name ?? member.user.email}</div>
              <div class="text-base-content/70 truncate text-xs">{member.user.email} · joined {formatDate(member.joined_at)}</div>
            </div>
          </a>
          {#if editable}
            <div class="w-40">
              <RoleSelect
                roles={detail.roles}
                value={member.role}
                class="select select-sm w-full"
                aria-label="Role of {member.user.email}"
                onchange={(e) => setRole(member, e.currentTarget.value)}
              />
            </div>
            <button class="btn btn-ghost btn-sm btn-square" aria-label="Remove {member.user.email}" onclick={() => { removing = member; confirmRemove?.open(); }}>
              <UserX class="size-4" />
            </button>
          {:else}
            <span class="badge {member.role.includes('owner') ? 'badge-primary' : 'badge-ghost'} badge-soft badge-sm">{member.role}</span>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>

<FormDialog bind:this={addDialog} title="Add a member" submitLabel="Add member" run={add}>
  <TextField label="Email" type="email" required autocomplete="off" hint="An existing user. To ask someone new, invite them." bind:value={adding.email} />
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">Role</span>
    <RoleSelect roles={detail.roles} bind:value={adding.role} required />
  </label>
</FormDialog>

<Confirm
  bind:this={confirmRemove}
  title="Remove {removing?.user.email ?? 'this member'}?"
  message="They lose access to this organization and its teams. Their account stays."
  confirmLabel="Remove member"
  danger
  run={remove}
/>
