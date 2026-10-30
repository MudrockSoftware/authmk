<script lang="ts">
  import CircleX from "@lucide/svelte/icons/circle-x";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import { api } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";

  // What needs attention, from the local health checks (no providers asked:
  // that's slow). Quiet when everything's fine, or the checks can't be read.
  const problems = api
    .health()
    .then((health) => health.checks.filter((check) => check.status === "failing" || check.status === "warning"))
    .catch(() => []);
</script>

{#await problems then checks}
  {#if checks.length > 0}
    <ul class="mb-6 flex flex-col gap-2" aria-label="Needs attention">
      {#each checks as check, index (`${index}:${check.name}`)}
        <li role="alert" class="alert {check.status === 'failing' ? 'alert-error' : 'alert-warning'} alert-soft">
          {#if check.status === "failing"}<CircleX class="size-5" aria-hidden="true" />{:else}<TriangleAlert class="size-5" aria-hidden="true" />{/if}
          <div class="text-sm">
            <span class="font-medium">{check.name}:</span>
            {check.message}
            {#if check.expires_at}<span class="text-base-content/70">({formatDate(check.expires_at)})</span>{/if}
          </div>
          <a href="#/integrations" class="btn btn-sm btn-ghost">Integrations</a>
        </li>
      {/each}
    </ul>
  {/if}
{/await}
