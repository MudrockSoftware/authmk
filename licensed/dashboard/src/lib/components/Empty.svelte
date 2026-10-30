<script lang="ts">
  import Inbox from "@lucide/svelte/icons/inbox";

  let { message }: { message: string } = $props();
</script>

<div class="text-base-content/70 flex flex-col items-center gap-2 py-10 text-center text-sm">
  <Inbox class="size-6" aria-hidden="true" />
  {message}
</div>
