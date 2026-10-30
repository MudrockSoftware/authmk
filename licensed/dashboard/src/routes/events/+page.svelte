<script lang="ts">
  import Filter from "@lucide/svelte/icons/filter";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api, type AuditEvent } from "#lib/api.ts";
  import { device, formatDateTime } from "#lib/format.ts";

  let eventName = $state("");
  let userId = $state("");
  let events = $state<AuditEvent[]>([]);
  let total = $state(0);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  async function load(more = false) {
    loading = true;
    failure = null;
    try {
      const page = await api.events({ event: eventName.trim(), user_id: userId.trim() }, more ? events.length : 0);
      events = more ? [...events, ...page.events] : page.events;
      total = page.total;
    } catch (error) {
      failure = error;
    } finally {
      loading = false;
    }
  }

  let timer: ReturnType<typeof setTimeout>;
  $effect(() => {
    void eventName;
    void userId;
    clearTimeout(timer);
    timer = setTimeout(() => load(), 250);
    return () => clearTimeout(timer);
  });

  function tone(name: string): string {
    if (name.endsWith(".deleted") || name.endsWith(".removed") || name.endsWith(".ended")) return "badge-warning";
    if (name.endsWith(".created") || name.endsWith(".added") || name.endsWith(".linked")) return "badge-success";
    return "badge-ghost";
  }
</script>

<PageHeader title="Audit log" description="Who did what to which account, newest first." />

<div class="mb-4 flex flex-wrap gap-2">
  <label class="input">
    <Filter class="size-4 opacity-60" aria-hidden="true" />
    <input placeholder="Event, like session.created" bind:value={eventName} aria-label="Filter by event" />
  </label>
  <label class="input">
    <input placeholder="User id" bind:value={userId} aria-label="Filter by user id" />
  </label>
  <span class="text-base-content/70 self-center text-sm tabular-nums">{total.toLocaleString("en-GB")} events</span>
</div>

{#if failure}<Failure error={failure} />{/if}

<div class="card border-base-300 bg-base-100 overflow-x-auto border">
  <table class="table">
    <thead><tr><th>When</th><th>Event</th><th>User</th><th>By</th><th>From</th></tr></thead>
    <tbody>
      {#each events as event (event.id)}
        <tr>
          <td class="text-sm whitespace-nowrap tabular-nums">{formatDateTime(event.created_at)}</td>
          <td><span class="badge {tone(event.event)} badge-soft font-mono text-xs">{event.event}</span></td>
          <td>{#if event.user_id}<a class="link font-mono text-xs" href="#/users/{event.user_id}">{event.user_id.slice(0, 8)}</a>{:else}—{/if}</td>
          <td>{#if event.actor_id}<a class="link font-mono text-xs" href="#/users/{event.actor_id}">{event.actor_id.slice(0, 8)}</a>{:else}—{/if}</td>
          <td class="text-xs">{event.ip_address ?? "—"}<div class="text-base-content/60">{event.user_agent ? device(event.user_agent) : ""}</div></td>
        </tr>
      {/each}
    </tbody>
  </table>
  {#if !loading && events.length === 0}<Empty message="No events match." />{/if}
</div>

{#if loading}<Loading />{/if}
{#if events.length < total && !loading}<div class="mt-4 flex justify-center"><button class="btn" onclick={() => load(true)}>Load more</button></div>{/if}
