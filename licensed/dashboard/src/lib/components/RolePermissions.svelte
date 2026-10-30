<script lang="ts">
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import type { Role } from "#lib/api.ts";

  // One role, where it comes from, and what it allows by resource.
  let { role }: { role: Role } = $props();

  const resources = $derived(Object.entries(role.permissions).sort(([a], [b]) => a.localeCompare(b)));
</script>

<div class="rounded-box border-base-300 border p-3">
  <div class="flex flex-wrap items-center gap-2">
    <span class="badge badge-primary badge-soft">{role.name}</span>
    <span class="text-base-content/70 text-xs">{role.source}</span>
    {#if !role.exists}
      <span class="badge badge-warning badge-soft badge-sm"><TriangleAlert class="size-3" aria-hidden="true" /> No longer exists: allows nothing</span>
    {/if}
  </div>
  {#if resources.length === 0}
    <p class="text-base-content/70 mt-2 text-xs">No permissions.</p>
  {:else}
    <dl class="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
      {#each resources as [resource, actions] (resource)}
        <dt class="font-mono font-medium">{resource}</dt>
        <dd class="flex flex-wrap gap-1">{#each actions as action (action)}<span class="badge badge-ghost badge-xs font-mono">{action}</span>{/each}</dd>
      {/each}
    </dl>
  {/if}
</div>
