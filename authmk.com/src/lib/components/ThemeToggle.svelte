<script lang="ts">
  import { onMount } from "svelte";
  import Moon from "@lucide/svelte/icons/moon";
  import Sun from "@lucide/svelte/icons/sun";
  import { theme } from "#lib/theme.svelte.ts";

  // The page is prerendered without knowing the visitor's theme, so the icon
  // is picked in CSS (`dark:`) and the pressed state is set once mounted.
  let mounted = $state(false);
  onMount(() => (mounted = true));
</script>

<button
  type="button"
  class="btn btn-square btn-ghost btn-sm"
  aria-label="Dark theme"
  title="Dark theme"
  aria-pressed={mounted ? theme.dark : undefined}
  onclick={theme.toggle}
>
  <Moon class="size-4 dark:hidden" aria-hidden="true" />
  <Sun class="hidden size-4 dark:block" aria-hidden="true" />
</button>
