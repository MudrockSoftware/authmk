<script lang="ts">
  import { initials } from "#lib/format.ts";

  let { name, email, size = "size-9" }: { name: string | null; email: string; size?: string } = $props();
</script>

<div class="avatar avatar-placeholder">
  <div class="bg-primary/15 text-primary rounded-full {size}">
    <span class="text-xs font-semibold">{initials(name, email)}</span>
  </div>
</div>
