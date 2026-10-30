<script lang="ts">
  import { api } from "#lib/api.ts";

  // Filters by organization: every organization, by name.
  let { value = $bindable(""), size = "" }: { value?: string; size?: string } = $props();

  const options = api.organizationOptions();
</script>

{#await options then data}
  <select class="select {size} w-auto" bind:value aria-label="Organization">
    <option value="">All organizations</option>
    {#each data.organizations as org (org.id)}<option value={org.id}>{org.name}</option>{/each}
  </select>
{:catch}
  <select class="select {size} w-auto" disabled aria-label="Organization"><option>Organizations unavailable</option></select>
{/await}
