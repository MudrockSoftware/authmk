<script lang="ts">
  import KeyRound from "@lucide/svelte/icons/key-round";
  import MailCheck from "@lucide/svelte/icons/mail-check";
  import UserCog from "@lucide/svelte/icons/user-cog";
  import Card from "#lib/components/Card.svelte";
  import FieldInput from "#lib/components/FieldInput.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import RoleField from "#lib/components/RoleField.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type UserDetail } from "#lib/api.ts";
  import { changedFields, drafts } from "#lib/fields.ts";
  import type { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  // Name, email, picture and the app's own fields; verifying the email,
  // setting a password and roles. Keyed on the user by the page, so the
  // form starts again from what's saved after every change.
  let { detail, outcome }: { detail: UserDetail; outcome: Outcome } = $props();

  const can = $derived(session.me!.can);
  const user = $derived(detail.user);

  const saved = () => ({ name: detail.user.name ?? "", email: detail.user.email, image: detail.user.image ?? "" });
  let draft = $state(saved());
  const savedFields = () => drafts(detail.fields, detail.user.fields);
  let fields = $state(savedFields());
  let saving = $state(false);
  let invalid = $state<string | null>(null);

  async function save(event: SubmitEvent) {
    event.preventDefault();
    invalid = null;
    let changes: Parameters<typeof api.updateUser>[1];
    try {
      changes = changesFromDraft();
    } catch (error) {
      invalid = error instanceof Error ? error.message : String(error);
      return;
    }
    if (Object.keys(changes).length === 0) {
      invalid = "Nothing has changed.";
      return;
    }
    saving = true;
    await outcome.attempt(() => api.updateUser(user.id, changes), "Profile saved.");
    saving = false;
  }

  // Only what changed, so the audit log says what did.
  function changesFromDraft() {
    const before = saved();
    const changes: Parameters<typeof api.updateUser>[1] = {};
    if (draft.name !== before.name) changes.name = draft.name.trim() || null;
    if (draft.email.trim() !== before.email) changes.email = draft.email.trim();
    if (draft.image !== before.image) changes.image = draft.image.trim() || null;
    const custom = changedFields(detail.fields, detail.user.fields, fields);
    if (Object.keys(custom).length > 0) changes.fields = custom;
    return changes;
  }

  let password = $state("");
  let role = $state("");
  let passwordDialog = $state<FormDialog>();
  let roleDialog = $state<FormDialog>();

  function openPassword() {
    password = "";
    passwordDialog?.open();
  }

  function openRole() {
    role = user.role ?? "";
    roleDialog?.open();
  }

  async function setPassword() {
    await api.setPassword(user.id, password);
    password = "";
    await outcome.done("Password set.");
  }

  async function setRole() {
    await api.setRole(user.id, role.trim());
    await outcome.done("Role saved.");
  }
</script>

<Card title="Profile">
  {#snippet actions()}
    {#if can.update_users && !user.email_verified}
      <button class="btn btn-sm" onclick={() => outcome.attempt(() => api.userAction(user.id, "verify-email"), "Email verified.")}>
        <MailCheck class="size-4" /> Mark email verified
      </button>
    {/if}
    {#if can.set_passwords}<button class="btn btn-sm" onclick={openPassword}><KeyRound class="size-4" /> Set password</button>{/if}
    {#if can.set_roles}<button class="btn btn-sm" onclick={openRole}><UserCog class="size-4" /> Set role</button>{/if}
  {/snippet}

  <form class="grid gap-3 sm:grid-cols-2" onsubmit={save}>
    <TextField label="Name" bind:value={draft.name} readonly={!can.update_users} autocomplete="off" />
    <TextField
      label="Email"
      type="email"
      required
      bind:value={draft.email}
      readonly={!can.update_users}
      autocomplete="off"
      hint={can.update_users ? "A new email isn't verified until they verify it, or you mark it verified." : undefined}
    />
    <div class="sm:col-span-2">
      <TextField label="Picture URL (optional)" type="url" bind:value={draft.image} readonly={!can.update_users} placeholder="https://" />
    </div>
    {#each detail.fields as field (field.name)}
      <div class={field.type === "map" || field.type === "text" ? "sm:col-span-2" : ""}>
        <FieldInput {field} bind:value={fields[field.name]} readonly={!can.update_users} />
      </div>
    {/each}
    {#if can.update_users}
      <div class="flex items-center gap-3 sm:col-span-2">
        <button class="btn btn-primary btn-sm" type="submit" disabled={saving}>
          {#if saving}<span class="loading loading-spinner loading-sm"></span>{/if}
          Save profile
        </button>
        {#if invalid}<p role="alert" class="text-error text-sm">{invalid}</p>{/if}
      </div>
    {/if}
  </form>
</Card>

<FormDialog bind:this={passwordDialog} title="Set a new password" submitLabel="Set password" run={setPassword}>
  <p class="text-base-content/80 text-sm">Tell them the new password in a safe way.</p>
  <TextField label="New password" type="password" required autocomplete="new-password" bind:value={password} />
</FormDialog>

<FormDialog bind:this={roleDialog} title="Set their role" submitLabel="Save role" run={setRole}>
  <RoleField required bind:value={role} />
</FormDialog>
