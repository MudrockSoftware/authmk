<script lang="ts">
  import Building2 from "@lucide/svelte/icons/building-2";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api, type Organization } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  let organizations = $state<Organization[]>([]);
  let hasMore = $state(false);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  async function load(more = false) {
    loading = true;
    try {
      const page = await api.organizations(more ? organizations.length : 0);
      organizations = more ? [...organizations, ...page.organizations] : page.organizations;
      hasMore = page.has_more;
    } catch (error) {
      failure = error;
    } finally {
      loading = false;
    }
  }

  load();
</script>

<PageHeader title="Organizations" description="Teams of users, with their members, invitations and single sign-on." />

{#if failure}<Failure error={failure} />{/if}

<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
  {#each organizations as org (org.id)}
    <a href="#/organizations/{org.id}" class="card border-base-300 bg-base-100 hover:border-primary border transition-colors">
      <div class="card-body flex-row items-center gap-4 p-5">
        <span class="bg-secondary/10 text-secondary rounded-field p-2.5"><Building2 class="size-5" aria-hidden="true" /></span>
        <div class="min-w-0">
          <div class="truncate font-medium">{org.name}</div>
          <div class="text-base-content/70 text-xs">{org.slug} · {org.members ?? 0} members · since {formatDate(org.created_at)}</div>
        </div>
      </div>
    </a>
  {/each}
</div>

{#if !loading && organizations.length === 0}<Empty message="No organizations yet." />{/if}
{#if loading}<Loading />{/if}
{#if hasMore && !loading}<div class="mt-4 flex justify-center"><button class="btn" onclick={() => load(true)}>Load more</button></div>{/if}
