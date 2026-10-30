<script lang="ts">
  import { page } from "$app/state";
  import Ban from "@lucide/svelte/icons/ban";
  import LogOut from "@lucide/svelte/icons/log-out";
  import Monitor from "@lucide/svelte/icons/monitor";
  import ShieldOff from "@lucide/svelte/icons/shield-off";
  import Undo2 from "@lucide/svelte/icons/undo-2";
  import Avatar from "#lib/components/Avatar.svelte";
  import Confirm from "#lib/components/Confirm.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import { api, type UserDetail } from "#lib/api.ts";
  import { device, formatDateTime, timeAgo } from "#lib/format.ts";
  import { session } from "#lib/session.svelte.ts";

  const id = $derived(page.params.id ?? "");
  const can = $derived(session.me!.can);

  let detail = $state<UserDetail | null>(null);
  let failure = $state<unknown>(null);
  let notice = $state<string | null>(null);

  async function load() {
    try {
      detail = await api.user(id);
    } catch (error) {
      failure = error;
    }
  }

  $effect(() => {
    void id;
    load();
  });

  async function act(action: "ban" | "unban" | "revoke-sessions" | "disable-two-factor", done: string) {
    await api.userAction(id, action);
    notice = done;
    await load();
  }

  async function revoke(sessionId: string) {
    try {
      await api.revokeSession(id, sessionId);
      notice = "Session revoked.";
      await load();
    } catch (error) {
      failure = error;
    }
  }

  let confirmBan = $state<Confirm>();
  let confirmRevokeAll = $state<Confirm>();
  let confirmTwoFactor = $state<Confirm>();
</script>

<a href="#/users" class="link link-hover text-base-content/70 text-sm">← Users</a>

{#if failure}<div class="mt-4"><Failure error={failure} /></div>{/if}

{#if detail}
  {@const user = detail.user}
  <section class="card border-base-300 bg-base-100 mt-4 border">
    <div class="card-body flex-row flex-wrap items-center gap-4">
      <Avatar name={user.name} email={user.email} size="size-14" />
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-semibold">{user.name ?? user.email}</h1>
        <div class="text-base-content/70 text-sm">{user.email} · joined {formatDateTime(user.created_at)}</div>
        <div class="mt-2 flex flex-wrap gap-1">
          {#if user.banned}<span class="badge badge-error">Banned{user.ban_reason ? `: ${user.ban_reason}` : ""}</span>{/if}
          {#if user.role}<span class="badge badge-primary badge-soft">{user.role}</span>{/if}
          <span class="badge {user.email_verified ? 'badge-success' : 'badge-ghost'} badge-soft">{user.email_verified ? "Email verified" : "Email not verified"}</span>
          {#if user.two_factor_enabled !== null}
            <span class="badge {user.two_factor_enabled ? 'badge-secondary' : 'badge-ghost'} badge-soft">Two-factor {user.two_factor_enabled ? "on" : "off"}</span>
          {/if}
        </div>
      </div>
      <div class="flex flex-wrap gap-2">
        {#if can.revoke_sessions && detail.sessions.length > 0}
          <button class="btn btn-sm" onclick={() => confirmRevokeAll?.open()}><LogOut class="size-4" /> Sign out everywhere</button>
        {/if}
        {#if can.update_users && user.two_factor_enabled}
          <button class="btn btn-sm" onclick={() => confirmTwoFactor?.open()}><ShieldOff class="size-4" /> Turn off two-factor</button>
        {/if}
        {#if can.ban && user.banned !== null}
          {#if user.banned}
            <button class="btn btn-sm" onclick={() => act("unban", "User unbanned.")}><Undo2 class="size-4" /> Unban</button>
          {:else}
            <button class="btn btn-sm btn-error btn-soft" onclick={() => confirmBan?.open()}><Ban class="size-4" /> Ban</button>
          {/if}
        {/if}
      </div>
    </div>
  </section>

  {#if notice}<div role="status" class="alert alert-success alert-soft mt-4">{notice}</div>{/if}

  <div class="mt-6 grid gap-6 xl:grid-cols-3">
    <section class="card border-base-300 bg-base-100 border xl:col-span-2">
      <div class="card-body">
        <h2 class="card-title text-base">Sessions</h2>
        {#if detail.sessions.length === 0}
          <Empty message="Not signed in anywhere." />
        {:else}
          <ul class="divide-base-300 divide-y">
            {#each detail.sessions as s (s.id)}
              <li class="flex items-center gap-3 py-3">
                <Monitor class="text-base-content/60 size-5" aria-hidden="true" />
                <div class="min-w-0 flex-1 text-sm">
                  <div class="font-medium">{device(s.user_agent)}{s.impersonated_by ? " (impersonated)" : ""}</div>
                  <div class="text-base-content/70 text-xs">{s.ip_address ?? "Unknown IP"} · started {timeAgo(s.created_at).toLowerCase()} · ends {formatDateTime(s.expires_at)}</div>
                </div>
                {#if can.revoke_sessions}<button class="btn btn-ghost btn-xs" onclick={() => revoke(s.id)}>Revoke</button>{/if}
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    </section>

    <div class="flex flex-col gap-6">
      <section class="card border-base-300 bg-base-100 border">
        <div class="card-body">
          <h2 class="card-title text-base">Sign-in methods</h2>
          {#if detail.accounts.length === 0}
            <Empty message="No sign-in methods." />
          {:else}
            <ul class="flex flex-wrap gap-2">
              {#each detail.accounts as account (account.provider)}
                <li class="badge badge-outline">{account.provider}</li>
              {/each}
            </ul>
          {/if}
        </div>
      </section>

      {#if detail.organizations.length > 0}
        <section class="card border-base-300 bg-base-100 border">
          <div class="card-body">
            <h2 class="card-title text-base">Organizations</h2>
            <ul class="divide-base-300 divide-y text-sm">
              {#each detail.organizations as org (org.id)}
                <li class="flex justify-between py-2">
                  <a class="link link-hover" href="#/organizations/{org.id}">{org.name}</a>
                  <span class="badge badge-ghost badge-sm">{org.role}</span>
                </li>
              {/each}
            </ul>
          </div>
        </section>
      {/if}
    </div>
  </div>

  {#if session.me?.features.audit_log}
    <section class="card border-base-300 bg-base-100 mt-6 border">
      <div class="card-body">
        <h2 class="card-title text-base">Recent activity</h2>
        {#if detail.events.length === 0}
          <Empty message="No activity recorded yet." />
        {:else}
          <ul class="timeline timeline-vertical timeline-compact">
            {#each detail.events as event, index (event.id)}
              <li>
                {#if index > 0}<hr />{/if}
                <div class="timeline-middle"><span class="bg-primary block size-2 rounded-full"></span></div>
                <div class="timeline-end mb-3 text-sm">
                  <code class="font-mono text-xs">{event.event}</code>
                  <div class="text-base-content/70 text-xs">{formatDateTime(event.created_at)}{event.ip_address ? ` · ${event.ip_address}` : ""}</div>
                </div>
                {#if index < detail.events.length - 1}<hr />{/if}
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    </section>
  {/if}

  <Confirm bind:this={confirmBan} title="Ban this user?" message="They're signed out everywhere and can't sign in until you unban them." confirmLabel="Ban user" danger run={() => act("ban", "User banned.")} />
  <Confirm bind:this={confirmRevokeAll} title="Sign this user out everywhere?" message="Every session ends. They can sign in again." confirmLabel="Sign out everywhere" run={() => act("revoke-sessions", "Signed out everywhere.")} />
  <Confirm
    bind:this={confirmTwoFactor}
    title="Turn off two-factor?"
    message="Their authenticator app and backup codes stop working. Only do this once you've confirmed who they are."
    confirmLabel="Turn off two-factor"
    danger
    run={() => act("disable-two-factor", "Two-factor turned off.")}
  />
{:else if !failure}
  <Loading />
{/if}
