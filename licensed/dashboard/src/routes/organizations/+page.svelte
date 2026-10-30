<script lang="ts">
  import { goto } from "$app/navigation";
  import Building2 from "@lucide/svelte/icons/building-2";
  import Plus from "@lucide/svelte/icons/plus";
  import Search from "@lucide/svelte/icons/search";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import FormDialog from "#lib/components/FormDialog.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type Organization } from "#lib/api.ts";
  import { formatDate } from "#lib/format.ts";
  import { session } from "#lib/session.svelte.ts";

  const canManage = $derived(session.me!.can.manage_organizations);

  let search = $state("");
  let organizations = $state<Organization[]>([]);
  let hasMore = $state(false);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  async function load(more = false) {
    loading = true;
    failure = null;
    try {
      const page = await api.organizations(search.trim(), more ? organizations.length : 0);
      organizations = more ? [...organizations, ...page.organizations] : page.organizations;
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

  let dialog = $state<FormDialog>();
  let draft = $state({ name: "", slug: "", owner_email: "" });
  // The slug follows the name until it's edited.
  let slugEdited = $state(false);

  const slugify = (name: string) =>
    name
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");

  function openNew() {
    draft = { name: "", slug: "", owner_email: "" };
    slugEdited = false;
    dialog?.open();
  }

  function nameChanged(name: string) {
    if (!slugEdited) draft.slug = slugify(name);
  }

  async function create() {
    const { id } = await api.createOrganization({ name: draft.name.trim(), slug: draft.slug.trim(), owner_email: draft.owner_email.trim() });
    await goto(`#/organizations/${id}`);
  }
</script>

<PageHeader title="Organizations" description="Teams of users, with their members, invitations and single sign-on.">
  {#snippet actions()}
    {#if canManage}<button class="btn btn-primary btn-sm" onclick={openNew}><Plus class="size-4" aria-hidden="true" /> New organization</button>{/if}
  {/snippet}
</PageHeader>

<label class="input mb-4 w-full max-w-md">
  <Search class="size-4 opacity-60" aria-hidden="true" />
  <input type="search" placeholder="Search by name or slug" bind:value={search} aria-label="Search organizations" />
</label>

{#if failure}<Failure error={failure} />{/if}

<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
  {#each organizations as org (org.id)}
    <a href="#/organizations/{org.id}" class="card border-base-300 bg-base-100 hover:border-primary border transition-colors">
      <div class="card-body flex-row items-center gap-4 p-5">
        <span class="bg-secondary/10 text-secondary rounded-field p-2.5"><Building2 class="size-5" aria-hidden="true" /></span>
        <div class="min-w-0">
          <div class="truncate font-medium">{org.name}</div>
          <div class="text-base-content/70 text-xs">{org.slug} · {org.members ?? 0} members · since {formatDate(org.created_at)}</div>
        </div>
      </div>
    </a>
  {/each}
</div>

{#if !loading && organizations.length === 0}<Empty message={search ? "No organizations match your search." : "No organizations yet."} />{/if}
{#if loading}<Loading />{/if}
{#if hasMore && !loading}<div class="mt-4 flex justify-center"><button class="btn" onclick={() => load(true)}>Load more</button></div>{/if}

<FormDialog bind:this={dialog} title="New organization" submitLabel="Create organization" run={create}>
  <TextField label="Name" required autocomplete="off" bind:value={draft.name} oninput={(e) => nameChanged(e.currentTarget.value)} />
  <TextField label="Slug" required autocomplete="off" hint="Used in URLs. Lowercase letters, numbers and dashes." bind:value={draft.slug} oninput={() => (slugEdited = true)} />
  <TextField label="Owner's email" type="email" required autocomplete="off" hint="An existing user; they become its owner." bind:value={draft.owner_email} />
</FormDialog>
