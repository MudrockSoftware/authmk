<script lang="ts">
  import Pencil from "@lucide/svelte/icons/pencil";
  import Plus from "@lucide/svelte/icons/plus";
  import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type AccessLevel, type AccessRole, type OrganizationDetail } from "#lib/api.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  // What this organization's member roles, team roles and roles within a
  // team allow (Authmk.Plugins.Gate). The app's code sets the defaults for
  // every organization; changes here apply to this one only, and can only
  // use the abilities the app lets organizations grant.
  let {
    detail,
    outcome,
    editable,
    teams
  }: { detail: OrganizationDetail; outcome: Outcome; editable: boolean; teams: boolean } = $props();

  const id = $derived(detail.organization.id);
  const access = $derived(detail.access!);

  const levelNames: Record<AccessLevel, string> = {
    organization: "Member roles",
    team: "Team roles",
    team_member: "Roles within a team"
  };

  const levels = $derived<AccessLevel[]>(teams ? ["organization", "team", "team_member"] : ["organization"]);
  const abilities = $derived(Object.entries(access.abilities).sort(([a], [b]) => a.localeCompare(b)));

  const sourceNames: Record<AccessRole["source"], string> = {
    code: "From the app",
    override: "Changed for this organization",
    organization: "This organization's own"
  };

  // The role being edited, or a new one.
  let editing = $state<AccessRole | null>(null);
  let level = $state<AccessLevel>("organization");
  let name = $state("");
  let granted = $state<Set<string>>(new Set());
  let roleDialog = $state<FormDialog>();
  let removing = $state<AccessRole | null>(null);
  let confirmRemove = $state<Confirm>();

  const key = (resource: string, action: string) => `${resource}:${action}`;

  function open(role: AccessRole | null) {
    editing = role;
    level = role?.level ?? "organization";
    name = role?.role ?? "";
    granted = new Set(Object.entries(role?.permission ?? {}).flatMap(([resource, actions]) => actions.map((action) => key(resource, action))));
    roleDialog?.open();
  }

  function toggle(resource: string, action: string, on: boolean) {
    const next = new Set(granted);
    if (on) next.add(key(resource, action));
    else next.delete(key(resource, action));
    granted = next;
  }

  async function save() {
    const permission: Record<string, string[]> = {};
    for (const [resource, actions] of abilities) {
      const chosen = actions.filter((action) => granted.has(key(resource, action)));
      if (chosen.length > 0) permission[resource] = chosen;
    }
    await api.setAccessRole(id, level, name.trim(), permission);
    await outcome.done(editing ? "Role saved." : "Role created.");
  }

  async function remove() {
    await api.deleteAccessRole(id, removing!.level, removing!.role);
    await outcome.done(removing!.source === "override" ? "Role reset to the app's default." : "Role deleted.");
  }

  const rolesAt = (level: AccessLevel) => access.roles.filter((role) => role.level === level);
</script>

<Card title="Access">
  {#snippet actions()}
    {#if editable}<button class="btn btn-sm" onclick={() => open(null)}><Plus class="size-4" /> New role</button>{/if}
  {/snippet}
  <p class="text-base-content/70 text-sm">
    What members may do here. Organization owners and admins may do everything. Teams pass their role's access on to their members; a role within a team only narrows it.
  </p>

  {#each levels as level (level)}
    <h3 class="mt-2 text-sm font-semibold">{levelNames[level]}</h3>
    {#if rolesAt(level).length === 0}
      <p class="text-base-content/70 text-xs">None.</p>
    {:else}
      <ul class="flex flex-col gap-2">
        {#each rolesAt(level) as role (role.role)}
          {@const resources = Object.entries(role.permission).sort(([a], [b]) => a.localeCompare(b))}
          <li class="rounded-box border-base-300 border p-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="badge badge-primary badge-soft">{role.role}</span>
              <span class="text-base-content/70 flex-1 text-xs">{sourceNames[role.source]}</span>
              {#if editable}
                <button class="btn btn-ghost btn-xs btn-square" aria-label="Edit {role.role}" onclick={() => open(role)}><Pencil class="size-3.5" /></button>
                {#if role.source === "override"}
                  <button class="btn btn-ghost btn-xs btn-square" aria-label="Reset {role.role} to the app's default" onclick={() => { removing = role; confirmRemove?.open(); }}><RotateCcw class="size-3.5" /></button>
                {:else if role.source === "organization"}
                  <button class="btn btn-ghost btn-xs btn-square text-error" aria-label="Delete {role.role}" onclick={() => { removing = role; confirmRemove?.open(); }}><Trash2 class="size-3.5" /></button>
                {/if}
              {/if}
            </div>
            {#if resources.length === 0}
              <p class="text-base-content/70 mt-2 text-xs">Allows nothing.</p>
            {:else}
              <dl class="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
                {#each resources as [resource, actions] (resource)}
                  <dt class="font-mono font-medium">{resource}</dt>
                  <dd class="flex flex-wrap gap-1">{#each actions as action (action)}<span class="badge badge-ghost badge-xs font-mono">{action}</span>{/each}</dd>
                {/each}
              </dl>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  {/each}
</Card>

<FormDialog bind:this={roleDialog} title={editing ? `Edit ${editing.role}` : "New role"} submitLabel={editing ? "Save role" : "Create role"} run={save}>
  {#if !editing}
    <label class="fieldset py-0">
      <span class="fieldset-legend pb-1">Kind</span>
      <select class="select w-full" bind:value={level}>
        {#each levels as level (level)}<option value={level}>{levelNames[level]}</option>{/each}
      </select>
    </label>
    <TextField
      label="Name"
      hint="Lowercase letters, digits, underscores and hyphens. A name the app already has changes that role for this organization."
      required
      maxlength={64}
      autocomplete="off"
      bind:value={name}
    />
  {/if}
  <fieldset class="fieldset">
    <legend class="fieldset-legend">Allows</legend>
    {#if abilities.length === 0}
      <p class="text-base-content/70 text-sm">The app lets organizations grant nothing.</p>
    {/if}
    {#each abilities as [resource, actions] (resource)}
      <div class="flex flex-wrap items-center gap-3 py-1">
        <span class="w-28 font-mono text-sm font-medium">{resource}</span>
        {#each actions as action (action)}
          <label class="flex items-center gap-1 text-sm">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={granted.has(key(resource, action))}
              onchange={(event) => toggle(resource, action, event.currentTarget.checked)}
            />
            <span class="font-mono">{action}</span>
          </label>
        {/each}
      </div>
    {/each}
  </fieldset>
</FormDialog>

<Confirm
  bind:this={confirmRemove}
  title={removing?.source === "override" ? `Reset ${removing?.role}?` : `Delete ${removing?.role ?? "this role"}?`}
  message={removing?.source === "override"
    ? "It goes back to what the app allows by default."
    : "Teams and people in teams must not have it any more."}
  confirmLabel={removing?.source === "override" ? "Reset role" : "Delete role"}
  danger={removing?.source !== "override"}
  run={remove}
/>
