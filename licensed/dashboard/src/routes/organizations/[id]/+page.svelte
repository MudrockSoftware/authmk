<script lang="ts">
  import { goto } from "$app/navigation";
  import { page } from "$app/state";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Card from "#lib/components/Card.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import OutcomeAlert from "#lib/components/OutcomeAlert.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import SubscriptionsCard from "#lib/components/SubscriptionsCard.svelte";
  import InvitationsCard from "#lib/components/organization/InvitationsCard.svelte";
  import MembersCard from "#lib/components/organization/MembersCard.svelte";
  import OrganizationProfileCard from "#lib/components/organization/OrganizationProfileCard.svelte";
  import TeamsCard from "#lib/components/organization/TeamsCard.svelte";
  import { api, type OrganizationDetail } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";
  import { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  const id = $derived(page.params.id ?? "");
  const me = $derived(session.me!);
  const editable = $derived(me.can.manage_organizations);

  let detail = $state<OrganizationDetail | null>(null);
  let failure = $state<unknown>(null);
  const outcome = new Outcome(load);
  let confirmDelete = $state<Confirm>();

  async function load() {
    try {
      detail = await api.organization(id);
      failure = null;
    } catch (error) {
      failure = error;
    }
  }

  $effect(() => {
    void id;
    outcome.notice = null;
    load();
  });

  async function remove() {
    await api.deleteOrganization(id);
    await goto("#/organizations");
  }
</script>

<a href="#/organizations" class="link link-hover text-base-content/70 text-sm">← Organizations</a>

{#if failure}<div class="mt-4"><Failure error={failure} /></div>{/if}

{#if detail}
  {@const org = detail.organization}
  <div class="mt-4">
    <PageHeader title={org.name} description="{org.slug} · since {formatDate(org.created_at)}">
      {#snippet actions()}
        {#if editable}<button class="btn btn-sm btn-error btn-soft" onclick={() => confirmDelete?.open()}><Trash2 class="size-4" /> Delete</button>{/if}
      {/snippet}
    </PageHeader>
  </div>

  <OutcomeAlert {outcome} />

  <div class="mt-4 grid gap-6 xl:grid-cols-3">
    <div class="flex flex-col gap-6 xl:col-span-2">
      <MembersCard {detail} {outcome} {editable} />
      {#key detail}<OrganizationProfileCard {detail} {outcome} {editable} />{/key}
    </div>

    <div class="flex flex-col gap-6">
      {#if me.features.teams}<TeamsCard {detail} {outcome} {editable} />{/if}
      <InvitationsCard {detail} {outcome} {editable} />
      {#if detail.sso_providers.length > 0 || detail.scim_connections.length > 0}
        <Card title="Single sign-on">
          <div class="text-sm">
            {#each detail.sso_providers as provider (provider.provider_id)}
              <div>{provider.provider_id} · {provider.domain ?? "no domain"} {provider.domain_verified ? "(verified)" : ""}</div>
            {/each}
            {#each detail.scim_connections as connection (connection.id)}
              <div>Directory sync: {connection.name ?? connection.id} · {connection.status}</div>
            {/each}
          </div>
        </Card>
      {/if}
    </div>
  </div>

  {#if me.features.payments}<div class="mt-6"><SubscriptionsCard subscriptions={detail.subscriptions} /></div>{/if}

  <Confirm
    bind:this={confirmDelete}
    title="Delete {org.name}?"
    message="The organization, its members, teams and invitations are deleted. Its members' accounts stay. This can't be undone."
    confirmLabel="Delete organization"
    danger
    run={remove}
  />
{:else if !failure}
  <Loading />
{/if}
