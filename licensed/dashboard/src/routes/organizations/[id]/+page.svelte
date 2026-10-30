<script lang="ts">
  import { page } from "$app/state";
  import Avatar from "#lib/components/Avatar.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  const detail = $derived(api.organization(page.params.id ?? ""));
</script>

<a href="#/organizations" class="link link-hover text-base-content/70 text-sm">← Organizations</a>

{#await detail}
  <Loading />
{:then data}
  <div class="mt-4"><PageHeader title={data.organization.name} description="{data.organization.slug} · since {formatDate(data.organization.created_at)}" /></div>

  <div class="grid gap-6 xl:grid-cols-3">
    <section class="card border-base-300 bg-base-100 border xl:col-span-2">
      <div class="card-body">
        <h2 class="card-title text-base">Members <span class="badge badge-ghost">{data.members.length}</span></h2>
        {#if data.members.length === 0}
          <Empty message="No members." />
        {:else}
          <ul class="divide-base-300 divide-y">
            {#each data.members as member (member.user.id)}
              <li>
                <a href="#/users/{member.user.id}" class="hover:bg-base-200 rounded-field flex items-center gap-3 px-2 py-2.5">
                  <Avatar name={member.user.name} email={member.user.email} />
                  <div class="min-w-0 flex-1 text-sm">
                    <div class="truncate font-medium">{member.user.name ?? member.user.email}</div>
                    <div class="text-base-content/70 truncate text-xs">{member.user.email}</div>
                  </div>
                  <span class="badge {member.role.includes('owner') ? 'badge-primary' : 'badge-ghost'} badge-soft badge-sm">{member.role}</span>
                </a>
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    </section>

    <div class="flex flex-col gap-6">
      <section class="card border-base-300 bg-base-100 border">
        <div class="card-body">
          <h2 class="card-title text-base">Teams</h2>
          {#if data.teams.length === 0}<Empty message="No teams." />{:else}
            <ul class="flex flex-wrap gap-2">{#each data.teams as team (team.id)}<li class="badge badge-outline">{team.name}</li>{/each}</ul>
          {/if}
        </div>
      </section>
      <section class="card border-base-300 bg-base-100 border">
        <div class="card-body">
          <h2 class="card-title text-base">Invitations</h2>
          {#if data.invitations.length === 0}<Empty message="No invitations." />{:else}
            <ul class="divide-base-300 divide-y text-sm">
              {#each data.invitations as invitation (invitation.id)}
                <li class="flex items-center justify-between py-2">
                  <span class="truncate">{invitation.email}</span>
                  <span class="badge badge-ghost badge-sm">{invitation.status}</span>
                </li>
              {/each}
            </ul>
          {/if}
        </div>
      </section>
      {#if data.sso_providers.length > 0 || data.scim_connections.length > 0}
        <section class="card border-base-300 bg-base-100 border">
          <div class="card-body text-sm">
            <h2 class="card-title text-base">Single sign-on</h2>
            {#each data.sso_providers as provider (provider.provider_id)}
              <div>{provider.provider_id} · {provider.domain ?? "no domain"} {provider.domain_verified ? "(verified)" : ""}</div>
            {/each}
            {#each data.scim_connections as connection (connection.id)}
              <div>Directory sync: {connection.name ?? connection.id} · {connection.status}</div>
            {/each}
          </div>
        </section>
      {/if}
    </div>
  </div>
{:catch error}
  <div class="mt-4"><Failure {error} /></div>
{/await}
