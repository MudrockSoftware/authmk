<script lang="ts">
  import type { HTMLInputAttributes } from "svelte/elements";

  // A labelled input for forms.
  let { label, hint, value = $bindable(), ...input }: { label: string; hint?: string; value?: string } & HTMLInputAttributes = $props();
</script>

<label class="fieldset py-0">
  <span class="fieldset-legend pb-1">{label}</span>
  <input class="input w-full" bind:value {...input} />
  {#if hint}<span class="label whitespace-normal">{hint}</span>{/if}
</label>
