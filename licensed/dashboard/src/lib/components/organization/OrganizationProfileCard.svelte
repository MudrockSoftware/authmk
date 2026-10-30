<script lang="ts">
  import Card from "#lib/components/Card.svelte";
  import FieldInput from "#lib/components/FieldInput.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type OrganizationDetail } from "#lib/api.ts";
  import { changedFields, drafts } from "#lib/fields.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";

  // Name, slug, logo and the app's own fields. Keyed on the organization by
  // the page, so the form starts again from what's saved after a change.
  let { detail, outcome, editable }: { detail: OrganizationDetail; outcome: Outcome; editable: boolean } = $props();

  const saved = () => ({ name: detail.organization.name, slug: detail.organization.slug, logo: detail.organization.logo ?? "" });
  const savedFields = () => drafts(detail.fields, detail.organization.fields);
  let draft = $state(saved());
  let fields = $state(savedFields());
  let saving = $state(false);
  let invalid = $state<string | null>(null);

  // Only what changed, so the audit log says what did.
  function changes() {
    const before = saved();
    const result: Parameters<typeof api.updateOrganization>[1] = {};
    if (draft.name.trim() !== before.name) result.name = draft.name.trim();
    if (draft.slug.trim() !== before.slug) result.slug = draft.slug.trim();
    if (draft.logo.trim() !== before.logo) result.logo = draft.logo.trim() || null;
    const custom = changedFields(detail.fields, detail.organization.fields, fields);
    if (Object.keys(custom).length > 0) result.fields = custom;
    return result;
  }

  async function save(event: SubmitEvent) {
    event.preventDefault();
    invalid = null;
    let update: ReturnType<typeof changes>;
    try {
      update = changes();
    } catch (error) {
      invalid = error instanceof Error ? error.message : String(error);
      return;
    }
    if (Object.keys(update).length === 0) {
      invalid = "Nothing has changed.";
      return;
    }
    saving = true;
    await outcome.attempt(() => api.updateOrganization(detail.organization.id, update), "Organization saved.");
    saving = false;
  }
</script>

<Card title="Details">
  <form class="grid gap-3 sm:grid-cols-2" onsubmit={save}>
    <TextField label="Name" required bind:value={draft.name} readonly={!editable} autocomplete="off" />
    <TextField label="Slug" required bind:value={draft.slug} readonly={!editable} autocomplete="off" />
    <div class="sm:col-span-2">
      <TextField label="Logo URL (optional)" type="url" placeholder="https://" bind:value={draft.logo} readonly={!editable} />
    </div>
    {#each detail.fields as field (field.name)}
      <div class={field.type === "map" || field.type === "text" ? "sm:col-span-2" : ""}>
        <FieldInput {field} bind:value={fields[field.name]} readonly={!editable} />
      </div>
    {/each}
    {#if editable}
      <div class="flex items-center gap-3 sm:col-span-2">
        <button class="btn btn-primary btn-sm" type="submit" disabled={saving}>
          {#if saving}<span class="loading loading-spinner loading-sm"></span>{/if}
          Save details
        </button>
        {#if invalid}<p role="alert" class="text-error text-sm">{invalid}</p>{/if}
      </div>
    {/if}
  </form>
</Card>
