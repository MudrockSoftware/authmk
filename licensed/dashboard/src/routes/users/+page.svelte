<script lang="ts">
  import Search from "@lucide/svelte/icons/search";
  import Avatar from "#lib/components/Avatar.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api, type User } from "#lib/api.ts";
  import { formatDate, timeAgo } from "#lib/format.ts";

  let search = $state("");
  let users = $state<User[]>([]);
  let hasMore = $state(false);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  async function load(more = false) {
    loading = true;
    failure = null;
    try {
      const page = await api.users(search, more ? users.length : 0);
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
    void search;
    clearTimeout(timer);
    timer = setTimeout(() => load(), 250);
    return () => clearTimeout(timer);
  });
</script>

<PageHeader title="Users" description="Everyone with an account. Open a user to manage their sessions, two-factor and bans." />

<label class="input mb-4 w-full max-w-md">
  <Search class="size-4 opacity-60" aria-hidden="true" />
  <input type="search" placeholder="Search by email or name" bind:value={search} aria-label="Search users" />
</label>

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
  {#if !loading && users.length === 0}<Empty message={search ? "No users match your search." : "No users yet."} />{/if}
</div>

{#if loading}<Loading />{/if}
{#if hasMore && !loading}
  <div class="mt-4 flex justify-center"><button class="btn" onclick={() => load(true)}>Load more</button></div>
{/if}
