<script lang="ts">
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import StatusBadge from "#lib/components/StatusBadge.svelte";
  import { api, type HealthCheck, type HealthStatus } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  let checks = $state<HealthCheck[] | null>(null);
  let network = $state(false);
  let checking = $state(false);
  let failure = $state<unknown>(null);

  // `withProviders` also asks each social and SSO provider: that takes seconds.
  async function load(withProviders: boolean) {
    checking = true;
    failure = null;
    try {
      const health = await api.health(withProviders);
      checks = health.checks;
      network = health.network;
    } catch (error) {
      failure = error;
    } finally {
      checking = false;
    }
  }

  load(false);

  // Checks by area, in the order the server lists them.
  const areas = $derived.by(() => {
    const groups = new Map<string, HealthCheck[]>();
    for (const check of checks ?? []) groups.set(check.area, [...(groups.get(check.area) ?? []), check]);
    return [...groups].map(([area, list]) => ({ area, checks: list }));
  });

  // An area's status: its worst check's.
  function worst(list: HealthCheck[]): HealthStatus {
    const order: HealthStatus[] = ["failing", "warning", "unknown", "ok"];
    return order.find((status) => list.some((check) => check.status === status)) ?? "ok";
  }
</script>

<PageHeader title="Integrations" description="What your app's sign-in depends on, and whether it's working: email and SMS, certificates and secrets, payments, storage and jobs.">
  {#snippet actions()}
    <button class="btn btn-primary btn-sm" onclick={() => load(true)} disabled={checking}>
      {#if checking && checks}<span class="loading loading-spinner loading-sm"></span>{:else}<RefreshCw class="size-4" aria-hidden="true" />{/if}
      Check providers
    </button>
  {/snippet}
</PageHeader>

{#if failure}<div class="mb-4"><Failure error={failure} /></div>{/if}

{#if checking && checks}
  <div role="status" class="alert alert-info alert-soft mb-4 text-sm">
    <span class="loading loading-spinner loading-sm"></span>
    Asking each social sign-in and SSO provider whether it knows your app. This can take several seconds.
  </div>
{:else if checks && !network}
  <p class="text-base-content/70 mb-4 text-sm">
    Social sign-in and SSO providers weren't asked: <strong>Check providers</strong> fetches their discovery documents and tries your client credentials.
  </p>
{/if}

{#if checks === null}
  {#if !failure}<Loading />{/if}
{:else if checks.length === 0}
  <Empty message="Nothing to check yet." />
{:else}
  <div class="grid gap-6 lg:grid-cols-2">
    {#each areas as group (group.area)}
      <Card title={group.area}>
        {#snippet actions()}<StatusBadge status={worst(group.checks)} />{/snippet}
        <ul class="divide-base-300 divide-y">
          {#each group.checks as check, index (`${index}:${check.name}`)}
            <li class="flex items-start gap-3 py-2.5 text-sm">
              <div class="min-w-0 flex-1">
                <div class="font-medium">{check.name}</div>
                <div class="text-base-content/70 text-xs">{check.message}</div>
                {#if check.expires_at}<div class="text-base-content/70 text-xs">Expires {formatDate(check.expires_at)}</div>{/if}
              </div>
              <StatusBadge status={check.status} />
            </li>
          {/each}
        </ul>
      </Card>
    {/each}
  </div>
{/if}
