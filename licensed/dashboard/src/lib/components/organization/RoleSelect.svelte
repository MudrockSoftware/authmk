<script lang="ts">
  import type { HTMLSelectAttributes } from "svelte/elements";

  // The organization's roles: built in, then its own. A role it no longer
  // has stays listed, so the current value shows.
  let {
    roles,
    value = $bindable(),
    ...select
  }: { roles: { name: string; built_in: boolean }[]; value: string } & HTMLSelectAttributes = $props();

  const builtIn = $derived(roles.filter((role) => role.built_in));
  const own = $derived(roles.filter((role) => !role.built_in));
  const unknown = $derived(value && !roles.some((role) => role.name === value) ? value : null);
</script>

<select class="select w-full" bind:value {...select}>
  {#if unknown}<option value={unknown}>{unknown}</option>{/if}
  {#if own.length === 0}
    {#each builtIn as role (role.name)}<option value={role.name}>{role.name}</option>{/each}
  {:else}
    <optgroup label="Built-in roles">{#each builtIn as role (role.name)}<option value={role.name}>{role.name}</option>{/each}</optgroup>
    <optgroup label="This organization's roles">{#each own as role (role.name)}<option value={role.name}>{role.name}</option>{/each}</optgroup>
  {/if}
</select>
