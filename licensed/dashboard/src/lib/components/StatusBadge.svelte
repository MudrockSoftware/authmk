<script lang="ts">
  import type { HealthStatus } from "#lib/api.ts";

  let { status }: { status: HealthStatus } = $props();

  const looks: Record<HealthStatus, { label: string; style: string }> = {
    ok: { label: "OK", style: "badge-success" },
    warning: { label: "Warning", style: "badge-warning" },
    failing: { label: "Failing", style: "badge-error" },
    unknown: { label: "Unknown", style: "badge-ghost" }
  };
</script>

<span class="badge {looks[status].style} badge-soft badge-sm whitespace-nowrap">{looks[status].label}</span>
