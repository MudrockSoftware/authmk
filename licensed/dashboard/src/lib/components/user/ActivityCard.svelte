<script lang="ts">
  import Card from "#lib/components/Card.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import type { AuditEvent } from "#lib/api.ts";
  import { formatDateTime } from "#lib/format.ts";

  let { events, userId }: { events: AuditEvent[]; userId: string } = $props();
</script>

<Card title="Recent activity">
  {#snippet actions()}<a href="#/events?user_id={userId}" class="link link-primary text-sm">Audit log</a>{/snippet}
  {#if events.length === 0}
    <Empty message="No activity recorded yet." />
  {:else}
    <ul class="timeline timeline-vertical timeline-compact">
      {#each events as event, index (event.id)}
        <li>
          {#if index > 0}<hr />{/if}
          <div class="timeline-middle"><span class="bg-primary block size-2 rounded-full"></span></div>
          <div class="timeline-end mb-3 text-sm">
            <code class="font-mono text-xs">{event.event}</code>
            <div class="text-base-content/70 text-xs">{formatDateTime(event.created_at)}{event.ip_address ? ` · ${event.ip_address}` : ""}</div>
          </div>
          {#if index < events.length - 1}<hr />{/if}
        </li>
      {/each}
    </ul>
  {/if}
</Card>
