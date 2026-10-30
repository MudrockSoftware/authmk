<script lang="ts">
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import type { ApiKey } from "#lib/api.ts";
  import { formatDate, timeAgo } from "#lib/format.ts";

  // Their API keys: only the first characters, never the key.
  let { keys }: { keys: ApiKey[] } = $props();

  function status(key: ApiKey) {
    if (!key.enabled) return { label: "Disabled", style: "badge-ghost" };
    if (key.expires_at && new Date(key.expires_at) <= new Date()) return { label: "Expired", style: "badge-warning" };
    return { label: "Active", style: "badge-success" };
  }

  const permissions = (key: ApiKey) =>
    key.permissions ? Object.entries(key.permissions).map(([resource, actions]) => `${resource}: ${actions.join(", ")}`) : [];
</script>

<Card title="API keys" count={keys.length}>
  {#if keys.length === 0}
    <Empty message="No API keys." />
  {:else}
    <div class="overflow-x-auto">
      <table class="table-sm table">
        <thead><tr><th>Key</th><th>Status</th><th>Permissions</th><th>Last used</th><th>Expires</th><th>Created</th></tr></thead>
        <tbody>
          {#each keys as key (key.id)}
            {@const state = status(key)}
            <tr>
              <td>
                <div class="font-medium">{key.name ?? "Unnamed"}</div>
                <div class="text-base-content/70 font-mono text-xs">{key.start ?? key.prefix ?? ""}…</div>
                {#if key.organization_id}<a class="link text-xs" href="#/organizations/{key.organization_id}">Organization's key</a>{/if}
              </td>
              <td><span class="badge {state.style} badge-soft badge-sm">{state.label}</span></td>
              <td class="font-mono text-xs">{#each permissions(key) as line (line)}<div>{line}</div>{:else}—{/each}</td>
              <td class="text-sm">{timeAgo(key.last_used_at)}</td>
              <td class="text-sm">{key.expires_at ? formatDate(key.expires_at) : "Never"}</td>
              <td class="text-sm">{formatDate(key.created_at)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</Card>
