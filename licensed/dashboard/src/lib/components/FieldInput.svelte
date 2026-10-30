<script lang="ts">
  import type { FieldDefinition } from "#lib/api.ts";
  import { humanise } from "#lib/format.ts";
  import type { Draft } from "#lib/fields.ts";

  // One of the app's own fields, as its type wants it. Read-only when the
  // app doesn't let it be changed, or the admin can't.
  let { field, value = $bindable(), readonly = false }: { field: FieldDefinition; value: Draft; readonly?: boolean } = $props();

  const locked = $derived(readonly || !field.editable);
  const label = $derived(`${humanise(field.name)}${field.required ? "" : " (optional)"}`);
</script>

{#if field.type === "boolean"}
  <label class="label text-base-content gap-2 py-2 text-sm">
    <input type="checkbox" class="checkbox checkbox-sm" checked={value === true} onchange={(e) => (value = e.currentTarget.checked)} disabled={locked} />
    {humanise(field.name)}
  </label>
{:else}
  <label class="fieldset py-0">
    <span class="fieldset-legend pb-1">{label}</span>
    {#if field.options}
      <select class="select w-full" bind:value disabled={locked}>
        {#if !field.required}<option value="">None</option>{/if}
        {#each field.options as option (option)}<option value={option}>{option}</option>{/each}
      </select>
    {:else if field.type === "map"}
      <textarea class="textarea w-full font-mono text-xs" rows="4" bind:value readonly={locked} placeholder={"{}"}></textarea>
    {:else if field.type === "text"}
      <textarea class="textarea w-full" rows="3" bind:value readonly={locked}></textarea>
    {:else if field.type === "integer"}
      <input class="input w-full" type="text" inputmode="numeric" pattern="-?[0-9]*" bind:value readonly={locked} />
    {:else if field.type === "datetime"}
      <input class="input w-full" type="datetime-local" bind:value readonly={locked} />
    {:else}
      <input class="input w-full" bind:value readonly={locked} />
    {/if}
    {#if locked && !readonly}<span class="label">Set by the app; it can't be changed here.</span>{/if}
  </label>
{/if}
