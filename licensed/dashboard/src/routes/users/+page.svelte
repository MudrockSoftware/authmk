<script lang="ts">
  import { goto } from "$app/navigation";
  import Download from "@lucide/svelte/icons/download";
  import Search from "@lucide/svelte/icons/search";
  import UserPlus from "@lucide/svelte/icons/user-plus";
  import Avatar from "#lib/components/Avatar.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import OrganizationSelect from "#lib/components/OrganizationSelect.svelte";
  import RoleField from "#lib/components/RoleField.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, exportUrl, type User, type UserFilters } from "#lib/api.ts";
  import { formatDate, timeAgo } from "#lib/format.ts";
  import { session } from "#lib/session.svelte.ts";

  const me = $derived(session.me!);

  let search = $state("");
  let status = $state("");
  let organizationId = $state("");
  let users = $state<User[]>([]);
  let hasMore = $state(false);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  const filters = $derived<UserFilters>({ search: search.trim(), status, organization_id: organizationId });
  const filtered = $derived(!!(filters.search || status || organizationId));

  async function load(more = false) {
    loading = true;
    failure = null;
    try {
      const page = await api.users(filters, more ? users.length : 0);
      users = more ? [...users, ...page.users] : page.users;
      hasMore = page.has_more;
    } catch (error) {
      failure = error;
    } finally {
      loading = false;
    }
  }

  // Searches as you type, after a short pause.
  let timer: ReturnType<typeof setTimeout>;
  $effect(() => {
    void filters;
    clearTimeout(timer);
    timer = setTimeout(() => load(), 250);
    return () => clearTimeout(timer);
  });

  let newUser = $state<FormDialog>();
  let draft = $state({ email: "", name: "", password: "", role: "" });

  function openNewUser() {
    draft = { email: "", name: "", password: "", role: "" };
    newUser?.open();
  }

  async function create() {
    const { user } = await api.createUser({
      email: draft.email.trim(),
      name: draft.name.trim(),
      password: draft.password || undefined,
      role: draft.role.trim() || undefined
    });
    await goto(`#/users/${user.id}`);
  }
</script>

<PageHeader title="Users" description="Everyone with an account. Open a user to manage their profile, sessions, two-factor and bans.">
  {#snippet actions()}
    <a class="btn btn-sm" href={exportUrl("users", filters)} download><Download class="size-4" aria-hidden="true" /> Export CSV</a>
    {#if me.can.create_users}
      <button class="btn btn-primary btn-sm" onclick={openNewUser}><UserPlus class="size-4" aria-hidden="true" /> New user</button>
    {/if}
  {/snippet}
</PageHeader>

<div class="mb-4 flex flex-wrap gap-2">
  <label class="input w-full max-w-md">
    <Search class="size-4 opacity-60" aria-hidden="true" />
    <input type="search" placeholder="Search by email or name" bind:value={search} aria-label="Search users" />
  </label>
  <select class="select w-auto" bind:value={status} aria-label="Status">
    <option value="">Any status</option>
    {#if me.features.admin}<option value="banned">Banned</option>{/if}
    <option value="unverified">Email not verified</option>
    {#if me.features.two_factor}<option value="two_factor">Two-factor on</option>{/if}
  </select>
  {#if me.features.organizations}<OrganizationSelect bind:value={organizationId} />{/if}
</div>

{#if failure}<Failure error={failure} />{/if}

<div class="card border-base-300 bg-base-100 overflow-x-auto border">
  <table class="table">
    <thead>
      <tr><th>User</th><th>Status</th><th>Joined</th><th>Last sign-in</th></tr>
    </thead>
    <tbody>
      {#each users as user (user.id)}
        <tr class="hover:bg-base-200">
          <td>
            <a href="#/users/{user.id}" class="flex items-center gap-3">
              <Avatar name={user.name} email={user.email} />
              <div>
                <div class="font-medium">{user.name ?? "—"}</div>
                <div class="text-base-content/70 text-xs">{user.email}</div>
              </div>
            </a>
          </td>
          <td>
            <div class="flex flex-wrap gap-1">
              {#if user.banned}<span class="badge badge-error badge-sm">Banned</span>{/if}
              {#if user.role && user.role !== "user"}<span class="badge badge-primary badge-soft badge-sm">{user.role}</span>{/if}
              {#if user.email_verified}<span class="badge badge-success badge-soft badge-sm">Verified</span>{:else}<span class="badge badge-ghost badge-sm">Not verified</span>{/if}
              {#if user.two_factor_enabled}<span class="badge badge-secondary badge-soft badge-sm">Two-factor</span>{/if}
            </div>
          </td>
          <td class="text-sm tabular-nums">{formatDate(user.created_at)}</td>
          <td class="text-sm">{timeAgo(user.last_sign_in_at)}</td>
        </tr>
      {/each}
    </tbody>
  </table>
  {#if !loading && users.length === 0}<Empty message={filtered ? "No users match these filters." : "No users yet."} />{/if}
</div>

{#if loading}<Loading />{/if}
{#if hasMore && !loading}
  <div class="mt-4 flex justify-center"><button class="btn" onclick={() => load(true)}>Load more</button></div>
{/if}

<FormDialog bind:this={newUser} title="New user" submitLabel="Create user" run={create}>
  <TextField label="Email" type="email" required autocomplete="off" bind:value={draft.email} />
  <TextField label="Name" required autocomplete="off" bind:value={draft.name} />
  <TextField
    label="Password (optional)"
    type="password"
    autocomplete="new-password"
    hint="Without one, they sign in another way, such as a magic link or resetting their password."
    bind:value={draft.password}
  />
  {#if me.can.set_roles}
    <RoleField label="Role (optional)" bind:value={draft.role} />
  {/if}
</FormDialog>
