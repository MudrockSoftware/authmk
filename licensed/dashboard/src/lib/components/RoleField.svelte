<script lang="ts">
  import TextField from "#lib/components/TextField.svelte";
  import { session } from "#lib/session.svelte.ts";

  // App roles (Authmk.Plugins.Admin's), suggested from the app's own list.
  // Free text still, for several at once: "admin,support".
  let { label = "Role", value = $bindable(), required = false }: { label?: string; value?: string; required?: boolean } = $props();

  const roles = $derived(session.me?.roles ?? []);
  const id = $props.id();
</script>

<TextField
  {label}
  {required}
  autocomplete="off"
  placeholder="user"
  list={`${id}-roles`}
  hint={roles.length > 0 ? `This app's roles: ${roles.join(", ")}. Several are separated by commas.` : "Several roles are separated by commas."}
  bind:value
/>
<datalist id={`${id}-roles`}>
  {#each roles as role (role)}<option value={role}></option>{/each}
</datalist>
