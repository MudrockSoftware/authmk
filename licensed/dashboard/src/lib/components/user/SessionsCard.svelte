<script lang="ts">
  import Monitor from "@lucide/svelte/icons/monitor";
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import { api, type Session } from "#lib/api.ts";
  import { device, formatDateTime, timeAgo } from "#lib/format.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  let { userId, sessions, outcome }: { userId: string; sessions: Session[]; outcome: Outcome } = $props();

  const can = $derived(session.me!.can);
</script>

<Card title="Sessions" count={sessions.length}>
  {#if sessions.length === 0}
    <Empty message="Not signed in anywhere." />
  {:else}
    <ul class="divide-base-300 divide-y">
      {#each sessions as s (s.id)}
        <li class="flex items-center gap-3 py-3">
          <Monitor class="text-base-content/60 size-5" aria-hidden="true" />
          <div class="min-w-0 flex-1 text-sm">
            <div class="font-medium">{device(s.user_agent)}{s.impersonated_by ? " (impersonated)" : ""}</div>
            <div class="text-base-content/70 text-xs">{s.ip_address ?? "Unknown IP"} · started {timeAgo(s.created_at).toLowerCase()} · ends {formatDateTime(s.expires_at)}</div>
          </div>
          {#if can.revoke_sessions}
            <button class="btn btn-ghost btn-xs" onclick={() => outcome.attempt(() => api.revokeSession(userId, s.id), "Session revoked.")}>Revoke</button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>
