<script lang="ts">
  import Failure from "#lib/components/Failure.svelte";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  let { outcome }: { outcome: Outcome } = $props();
</script>

{#if outcome.notice}<div role="status" class="alert alert-success alert-soft mt-4">{outcome.notice}</div>{/if}
{#if outcome.failure}<div class="mt-4"><Failure error={outcome.failure} /></div>{/if}
