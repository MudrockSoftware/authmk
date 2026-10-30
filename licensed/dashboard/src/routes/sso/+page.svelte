<script lang="ts">
  import CircleCheck from "@lucide/svelte/icons/circle-check";
  import CircleDashed from "@lucide/svelte/icons/circle-dashed";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api } from "#lib/api.ts";
  import { formatDate, timeAgo } from "#lib/format.ts";

  const data = api.sso();
</script>

<PageHeader title="SSO and SCIM" description="Your customers' identity providers, and the directories that provision their people." />

{#await data}
  <Loading />
{:then sso}
  <section class="card border-base-300 bg-base-100 border">
    <div class="card-body">
      <h2 class="card-title text-base">Identity providers</h2>
      {#if sso.providers.length === 0}<Empty message="No identity providers yet." />{:else}
        <div class="overflow-x-auto">
          <table class="table">
            <thead><tr><th>Provider</th><th>Issuer</th><th>Domain</th><th>Organization</th><th>Added</th></tr></thead>
            <tbody>
              {#each sso.providers as provider (provider.provider_id)}
                <tr>
                  <td class="font-medium">{provider.provider_id}</td>
                  <td class="font-mono text-xs">{provider.issuer}</td>
                  <td>
                    <span class="inline-flex items-center gap-1">
                      {#if provider.domain_verified}<CircleCheck class="text-success size-4" aria-label="Verified" />{:else}<CircleDashed class="text-base-content/60 size-4" aria-label="Not verified" />{/if}
                      {provider.domain ?? "—"}
                    </span>
                  </td>
                  <td>{#if provider.organization_id}<a class="link" href="#/organizations/{provider.organization_id}">Open</a>{:else}—{/if}</td>
                  <td class="text-sm">{formatDate(provider.created_at)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>
  </section>

  <section class="card border-base-300 bg-base-100 mt-6 border">
    <div class="card-body">
      <h2 class="card-title text-base">Directory sync (SCIM)</h2>
      {#if sso.connections.length === 0}<Empty message="No directories connected yet." />{:else}
        <div class="overflow-x-auto">
          <table class="table">
            <thead><tr><th>Connection</th><th>Status</th><th>Organization</th><th>Last used</th></tr></thead>
            <tbody>
              {#each sso.connections as connection (connection.id)}
                <tr>
                  <td class="font-medium">{connection.name ?? connection.id}</td>
                  <td><span class="badge {connection.status === 'active' ? 'badge-success' : 'badge-ghost'} badge-soft badge-sm">{connection.status}</span></td>
                  <td>{#if connection.organization_id}<a class="link" href="#/organizations/{connection.organization_id}">Open</a>{:else}—{/if}</td>
                  <td class="text-sm">{timeAgo(connection.last_used_at)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>
  </section>
{:catch error}
  <Failure {error} />
{/await}
