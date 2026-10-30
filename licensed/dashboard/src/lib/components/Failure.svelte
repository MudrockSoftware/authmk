<script lang="ts">
  import CircleAlert from "@lucide/svelte/icons/circle-alert";

  let { error }: { error: unknown } = $props();
  const message = $derived(error instanceof Error ? error.message : "Something went wrong. Try again.");
</script>

<div role="alert" class="alert alert-error alert-soft">
  <CircleAlert class="size-5" aria-hidden="true" />
  <span>{message}</span>
</div>
