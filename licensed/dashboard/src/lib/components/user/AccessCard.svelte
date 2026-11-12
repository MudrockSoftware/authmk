<script lang="ts">
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import RolePermissions from "#lib/components/RolePermissions.svelte";
  import type { Access } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  // Their app roles, and their roles and teams in each organization, with
  // what each allows: worked out by the same rules the plugins check. With
  // Authmk.Plugins.Gate, also the app's abilities they have there.
  let { access }: { access: Access } = $props();

  const abilityList = (abilities: Record<string, string[]>) =>
    Object.entries(abilities).sort(([a], [b]) => a.localeCompare(b));
</script>

{#snippet abilities(granted: Record<string, string[]>, where: string)}
  <div class="text-xs">
    <span class="text-base-content/70">Can do {where}:</span>
    {#if abilityList(granted).length === 0}
      <span class="text-base-content/70">nothing.</span>
    {:else}
      <dl class="mt-1 grid gap-x-4 gap-y-1 sm:grid-cols-[auto_1fr]">
        {#each abilityList(granted) as [resource, actions] (resource)}
          <dt class="font-mono font-medium">{resource}</dt>
          <dd class="flex flex-wrap gap-1">{#each actions as action (action)}<span class="badge badge-ghost badge-xs font-mono">{action}</span>{/each}</dd>
        {/each}
      </dl>
    {/if}
  </div>
{/snippet}

<Card title="What they can see and do">
  {#if access.app}
    <h3 class="text-sm font-semibold">In the app</h3>
    {#if access.app.all_admin_actions}
      <div role="note" class="alert alert-info alert-soft text-sm">
        <ShieldCheck class="size-4" aria-hidden="true" />
        Listed in the Admin plugin's <code class="font-mono">admin_user_ids</code>: every admin action is allowed, whatever their roles.
      </div>
    {/if}
    {#if access.app.roles.length === 0}
      <p class="text-base-content/70 text-sm">No app role.</p>
    {:else}
      <div class="flex flex-col gap-2">
        {#each access.app.roles as role (role.name)}<RolePermissions {role} />{/each}
      </div>
    {/if}
    {#if access.app.abilities}{@render abilities(access.app.abilities, "everywhere")}{/if}
  {/if}

  {#each access.organizations as org (org.id)}
    <div class="border-base-300 mt-2 flex flex-col gap-2 border-t pt-3">
      <h3 class="text-sm font-semibold">
        <a class="link link-hover" href="#/organizations/{org.id}">{org.name}</a>
        <span class="text-base-content/70 font-normal">· member since {formatDate(org.joined_at)}</span>
      </h3>
      {#each org.roles as role (role.name)}<RolePermissions {role} />{/each}
      {#if org.teams.length > 0}
        <div class="flex flex-wrap items-center gap-1 text-xs">
          <span class="text-base-content/70">Teams:</span>
          {#each org.teams as team (team.id)}
            <span class="badge badge-outline badge-sm">
              {team.name}{#if team.role}<span class="opacity-70">· {team.role}{team.member_role ? `, as ${team.member_role}` : ""}</span>{/if}
            </span>
          {/each}
        </div>
      {/if}
      {#if org.abilities}{@render abilities(org.abilities, `in ${org.name}`)}{/if}
    </div>
  {/each}

  {#if !access.app && access.organizations.length === 0}
    <Empty message="No roles: they can use only what every signed-in user can." />
  {/if}
</Card>
