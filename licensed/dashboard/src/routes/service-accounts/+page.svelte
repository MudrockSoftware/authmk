<script lang="ts">
  import Ban from "@lucide/svelte/icons/ban";
  import Play from "@lucide/svelte/icons/play";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import { api, type ServiceAccount } from "#lib/api.ts";
  import { formatDate, timeAgo } from "#lib/format.ts";
  import { session } from "#lib/session.svelte.ts";

  const can = $derived(session.me!.can.manage_service_accounts);

  let accounts = $state<ServiceAccount[] | null>(null);
  let hasMore = $state(false);
  let failure = $state<unknown>(null);
  let notice = $state<string | null>(null);
  let deleting = $state<ServiceAccount | null>(null);
  let confirmDelete = $state<Confirm>();

  async function load(offset = 0) {
    try {
      const page = await api.serviceAccounts(offset);
      accounts = offset === 0 ? page.service_accounts : [...(accounts ?? []), ...page.service_accounts];
      hasMore = page.has_more;
    } catch (error) {
      failure = error;
    }
  }

  load();

  async function act(account: ServiceAccount, action: "disable" | "enable" | "delete", done: string) {
    await api.serviceAccountAction(account.id, action);
    notice = done;
    await load();
  }

  function status(account: ServiceAccount) {
    if (account.disabled) return { label: "Disabled", style: "badge-ghost" };
    if (account.expires_at && new Date(account.expires_at) <= new Date()) return { label: "Expired", style: "badge-warning" };
    return { label: "Active", style: "badge-success" };
  }
</script>

<PageHeader title="Service accounts" description="Programs that call your app with API keys or OAuth client credentials, not people." />

{#if notice}<div role="status" class="alert alert-success alert-soft mb-4">{notice}</div>{/if}
{#if failure}<Failure error={failure} />{/if}

{#if accounts === null && !failure}
  <Loading />
{:else if accounts}
  <section class="card border-base-300 bg-base-100 border">
    <div class="card-body">
      {#if accounts.length === 0}<Empty message="No service accounts yet." />{:else}
        <div class="overflow-x-auto">
          <table class="table">
            <thead><tr><th>Name</th><th>Owner</th><th>Role</th><th>Status</th><th>Credentials</th><th>Last used</th><th>Created</th>{#if can}<th><span class="sr-only">Actions</span></th>{/if}</tr></thead>
            <tbody>
              {#each accounts as account (account.id)}
                {@const state = status(account)}
                <tr>
                  <td>
                    <div class="font-medium">{account.name}</div>
                    {#if account.description}<div class="text-base-content/70 text-xs">{account.description}</div>{/if}
                  </td>
                  <td>
                    {#if account.organization_id}<a class="link" href="#/organizations/{account.organization_id}">Organization</a>
                    {:else if account.user_id}<a class="link" href="#/users/{account.user_id}">User</a>
                    {:else}—{/if}
                  </td>
                  <td>{account.role ?? "—"}</td>
                  <td><span class="badge {state.style} badge-soft badge-sm">{state.label}</span></td>
                  <td class="text-sm">{account.oauth_client ? "API keys, OAuth client" : "API keys"}</td>
                  <td class="text-sm">{timeAgo(account.last_used_at)}</td>
                  <td class="text-sm">{formatDate(account.created_at)}</td>
                  {#if can}
                    <td class="text-right whitespace-nowrap">
                      {#if account.disabled}
                        <button class="btn btn-ghost btn-sm" onclick={() => act(account, "enable", "Service account enabled.")}><Play class="size-4" /> Enable</button>
                      {:else}
                        <button class="btn btn-ghost btn-sm" onclick={() => act(account, "disable", "Service account disabled.")}><Ban class="size-4" /> Disable</button>
                      {/if}
                      <button class="btn btn-ghost btn-sm text-error" onclick={() => { deleting = account; confirmDelete?.open(); }}><Trash2 class="size-4" /> Delete</button>
                    </td>
                  {/if}
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
        {#if hasMore}<button class="btn btn-ghost btn-sm mt-2 self-start" onclick={() => load(accounts!.length)}>Show more</button>{/if}
      {/if}
    </div>
  </section>
{/if}

<Confirm
  bind:this={confirmDelete}
  title="Delete this service account?"
  message="Its API keys and OAuth client stop working at once. This can't be undone."
  confirmLabel="Delete service account"
  danger
  run={() => act(deleting!, "delete", "Service account deleted.")}
/>
